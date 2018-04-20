// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include "arrow/gpu/cuda_memory.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <mutex>

#include <cuda.h>

#include "arrow/buffer.h"
#include "arrow/io/memory.h"
#include "arrow/status.h"
#include "arrow/util/logging.h"

#include "arrow/gpu/cuda_common.h"
#include "arrow/gpu/cuda_context.h"

namespace arrow {
namespace gpu {

// ----------------------------------------------------------------------
// CUDA IPC memory handle

struct CudaIpcMemHandle::CudaIpcMemHandleImpl {
  explicit CudaIpcMemHandleImpl(const void* handle) {
    memcpy(&ipc_handle, handle, sizeof(CUipcMemHandle));
  }

  CUipcMemHandle ipc_handle;
};

CudaIpcMemHandle::CudaIpcMemHandle(const void* handle) {
  impl_.reset(new CudaIpcMemHandleImpl(handle));
}

CudaIpcMemHandle::~CudaIpcMemHandle() {}

Status CudaIpcMemHandle::FromBuffer(const void* opaque_handle,
                                    std::shared_ptr<CudaIpcMemHandle>* handle) {
  *handle = std::shared_ptr<CudaIpcMemHandle>(new CudaIpcMemHandle(opaque_handle));
  return Status::OK();
}

Status CudaIpcMemHandle::Serialize(MemoryPool* pool, std::shared_ptr<Buffer>* out) const {
  std::shared_ptr<Buffer> buffer;
  constexpr size_t kHandleSize = sizeof(CUipcMemHandle);
  RETURN_NOT_OK(AllocateBuffer(pool, static_cast<int64_t>(kHandleSize), &buffer));
  memcpy(buffer->mutable_data(), &impl_->ipc_handle, kHandleSize);
  *out = buffer;
  return Status::OK();
}

const void* CudaIpcMemHandle::handle() const { return &impl_->ipc_handle; }

// ----------------------------------------------------------------------

CudaBuffer::CudaBuffer(uint8_t* data, int64_t size,
                       const std::shared_ptr<CudaContext>& context, bool own_data,
                       bool is_ipc)
    : Buffer(data, size), context_(context), own_data_(own_data), is_ipc_(is_ipc) {
  is_mutable_ = true;
  mutable_data_ = data;
}

CudaBuffer::~CudaBuffer() { DCHECK(Close().ok()); }

Status CudaBuffer::Close() {
  if (own_data_) {
    if (is_ipc_) {
      CU_RETURN_NOT_OK(cuIpcCloseMemHandle(reinterpret_cast<CUdeviceptr>(mutable_data_)));
    } else {
      return context_->Free(mutable_data_, size_);
    }
  }
  return Status::OK();
}

CudaBuffer::CudaBuffer(const std::shared_ptr<CudaBuffer>& parent, const int64_t offset,
                       const int64_t size)
    : Buffer(parent, offset, size),
      context_(parent->context()),
      own_data_(false),
      is_ipc_(false) {}

Status CudaBuffer::CopyToHost(const int64_t position, const int64_t nbytes,
                              void* out) const {
  return context_->CopyDeviceToHost(out, data_ + position, nbytes);
}

Status CudaBuffer::CopyFromHost(const int64_t position, const void* data,
                                int64_t nbytes) {
  DCHECK_LE(nbytes, size_ - position) << "Copy would overflow buffer";
  return context_->CopyHostToDevice(mutable_data_ + position, data, nbytes);
}

Status CudaBuffer::ExportForIpc(std::shared_ptr<CudaIpcMemHandle>* handle) {
  if (is_ipc_) {
    return Status::Invalid("Buffer has already been exported for IPC");
  }
  RETURN_NOT_OK(context_->ExportIpcBuffer(mutable_data_, handle));
  own_data_ = false;
  return Status::OK();
}

CudaHostBuffer::~CudaHostBuffer() {
  CudaDeviceManager* manager = nullptr;
  DCHECK(CudaDeviceManager::GetInstance(&manager).ok());
  DCHECK(manager->FreeHost(mutable_data_, size_).ok());
}

// ----------------------------------------------------------------------
// CudaBufferReader

CudaBufferReader::CudaBufferReader(const std::shared_ptr<CudaBuffer>& buffer)
    : io::BufferReader(buffer), cuda_buffer_(buffer), context_(buffer->context()) {}

CudaBufferReader::~CudaBufferReader() {}

Status CudaBufferReader::Read(int64_t nbytes, int64_t* bytes_read, void* buffer) {
  nbytes = std::min(nbytes, size_ - position_);
  *bytes_read = nbytes;
  RETURN_NOT_OK(context_->CopyDeviceToHost(buffer, data_ + position_, nbytes));
  position_ += nbytes;
  return Status::OK();
}

Status CudaBufferReader::Read(int64_t nbytes, std::shared_ptr<Buffer>* out) {
  int64_t size = std::min(nbytes, size_ - position_);
  *out = std::make_shared<CudaBuffer>(cuda_buffer_, position_, size);
  position_ += size;
  return Status::OK();
}

// ----------------------------------------------------------------------
// CudaBufferWriter

class CudaBufferWriter::CudaBufferWriterImpl {
 public:
  explicit CudaBufferWriterImpl(const std::shared_ptr<CudaBuffer>& buffer)
      : context_(buffer->context()),
        buffer_(buffer),
        buffer_size_(0),
        buffer_position_(0) {
    buffer_ = buffer;
    DCHECK(buffer->is_mutable()) << "Must pass mutable buffer";
    mutable_data_ = buffer->mutable_data();
    size_ = buffer->size();
    position_ = 0;
  }

  Status Seek(int64_t position) {
    if (position < 0 || position >= size_) {
      return Status::IOError("position out of bounds");
    }
    position_ = position;
    return Status::OK();
  }

  Status Flush() {
    if (buffer_size_ > 0 && buffer_position_ > 0) {
      // Only need to flush when the write has been buffered
      RETURN_NOT_OK(
          context_->CopyHostToDevice(mutable_data_ + position_ - buffer_position_,
                                     host_buffer_data_, buffer_position_));
      buffer_position_ = 0;
    }
    return Status::OK();
  }

  Status Tell(int64_t* position) const {
    *position = position_;
    return Status::OK();
  }

  Status Write(const void* data, int64_t nbytes) {
    if (nbytes == 0) {
      return Status::OK();
    }

    if (buffer_size_ > 0) {
      if (nbytes + buffer_position_ >= buffer_size_) {
        // Reach end of buffer, write everything
        RETURN_NOT_OK(Flush());
        RETURN_NOT_OK(
            context_->CopyHostToDevice(mutable_data_ + position_, data, nbytes));
      } else {
        // Write bytes to buffer
        std::memcpy(host_buffer_data_ + buffer_position_, data, nbytes);
        buffer_position_ += nbytes;
      }
    } else {
      // Unbuffered write
      RETURN_NOT_OK(context_->CopyHostToDevice(mutable_data_ + position_, data, nbytes));
    }
    position_ += nbytes;
    return Status::OK();
  }

  Status WriteAt(int64_t position, const void* data, int64_t nbytes) {
    std::lock_guard<std::mutex> guard(lock_);
    RETURN_NOT_OK(Seek(position));
    return Write(data, nbytes);
  }

  Status SetBufferSize(const int64_t buffer_size) {
    if (buffer_position_ > 0) {
      // Flush any buffered data
      RETURN_NOT_OK(Flush());
    }
    RETURN_NOT_OK(AllocateCudaHostBuffer(buffer_size, &host_buffer_));
    host_buffer_data_ = host_buffer_->mutable_data();
    buffer_size_ = buffer_size;
    return Status::OK();
  }

  int64_t buffer_size() const { return buffer_size_; }

  int64_t buffer_position() const { return buffer_position_; }

 private:
  std::shared_ptr<CudaContext> context_;
  std::shared_ptr<CudaBuffer> buffer_;
  std::mutex lock_;
  uint8_t* mutable_data_;
  int64_t size_;
  int64_t position_;

  // Pinned host buffer for buffering writes on CPU before calling cudaMalloc
  int64_t buffer_size_;
  int64_t buffer_position_;
  std::shared_ptr<CudaHostBuffer> host_buffer_;
  uint8_t* host_buffer_data_;
};

CudaBufferWriter::CudaBufferWriter(const std::shared_ptr<CudaBuffer>& buffer) {
  impl_.reset(new CudaBufferWriterImpl(buffer));
}

CudaBufferWriter::~CudaBufferWriter() {}

Status CudaBufferWriter::Close() { return Flush(); }

Status CudaBufferWriter::Flush() { return impl_->Flush(); }

Status CudaBufferWriter::Seek(int64_t position) {
  if (impl_->buffer_position() > 0) {
    RETURN_NOT_OK(Flush());
  }
  return impl_->Seek(position);
}

Status CudaBufferWriter::Tell(int64_t* position) const { return impl_->Tell(position); }

Status CudaBufferWriter::Write(const void* data, int64_t nbytes) {
  return impl_->Write(data, nbytes);
}

Status CudaBufferWriter::WriteAt(int64_t position, const void* data, int64_t nbytes) {
  return impl_->WriteAt(position, data, nbytes);
}

Status CudaBufferWriter::SetBufferSize(const int64_t buffer_size) {
  return impl_->SetBufferSize(buffer_size);
}

int64_t CudaBufferWriter::buffer_size() const { return impl_->buffer_size(); }

int64_t CudaBufferWriter::num_bytes_buffered() const { return impl_->buffer_position(); }

// ----------------------------------------------------------------------

Status AllocateCudaHostBuffer(const int64_t size, std::shared_ptr<CudaHostBuffer>* out) {
  CudaDeviceManager* manager = nullptr;
  RETURN_NOT_OK(CudaDeviceManager::GetInstance(&manager));
  return manager->AllocateHost(size, out);
}

}  // namespace gpu
}  // namespace arrow
