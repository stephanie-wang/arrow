# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

context("Datasets")

library(dplyr)

tempdir <- function() {
  path <- tempfile()
  dir.create(path)
  normalizePath(path, winslash = "/")
}

dataset_dir <- tempdir()
hive_dir <- tempdir()
ipc_dir <- tempdir()

first_date <- lubridate::ymd_hms("2015-04-29 03:12:39")
df1 <- tibble(
  int = 1:10,
  dbl = as.numeric(1:10),
  lgl = rep(c(TRUE, FALSE, NA, TRUE, FALSE), 2),
  chr = letters[1:10],
  fct = factor(LETTERS[1:10]),
  ts = first_date + lubridate::days(1:10)
)

second_date <- lubridate::ymd_hms("2017-03-09 07:01:02")
df2 <- tibble(
  int = 101:110,
  dbl = as.numeric(51:60),
  lgl = rep(c(TRUE, FALSE, NA, TRUE, FALSE), 2),
  chr = letters[10:1],
  fct = factor(LETTERS[10:1]),
  ts = second_date + lubridate::days(10:1)
)

test_that("Setup (putting data in the dir)", {
  dir.create(file.path(dataset_dir, 1))
  dir.create(file.path(dataset_dir, 2))
  write_parquet(df1, file.path(dataset_dir, 1, "file1.parquet"))
  write_parquet(df2, file.path(dataset_dir, 2, "file2.parquet"))
  expect_length(dir(dataset_dir, recursive = TRUE), 2)

  dir.create(file.path(hive_dir, "subdir", "group=1", "other=xxx"), recursive = TRUE)
  dir.create(file.path(hive_dir, "subdir", "group=2", "other=yyy"), recursive = TRUE)
  write_parquet(df1, file.path(hive_dir, "subdir", "group=1", "other=xxx", "file1.parquet"))
  write_parquet(df2, file.path(hive_dir, "subdir", "group=2", "other=yyy", "file2.parquet"))
  expect_length(dir(hive_dir, recursive = TRUE), 2)

  # Now, an IPC format dataset
  dir.create(file.path(ipc_dir, 3))
  dir.create(file.path(ipc_dir, 4))
  write_arrow(df1, file.path(ipc_dir, 3, "file1.arrow"))
  write_arrow(df2, file.path(ipc_dir, 4, "file2.arrow"))
  expect_length(dir(ipc_dir, recursive = TRUE), 2)
})

test_that("Simple interface for datasets", {
  ds <- open_dataset(dataset_dir, partitioning = schema(part = uint8()))
  expect_is(ds, "Dataset")
  expect_equivalent(
    ds %>%
      select(chr, dbl) %>%
      filter(dbl > 7 & dbl < 53L) %>% # Testing the auto-casting of scalars
      collect() %>%
      arrange(dbl),
    rbind(
      df1[8:10, c("chr", "dbl")],
      df2[1:2, c("chr", "dbl")]
    )
  )

  expect_equivalent(
    ds %>%
      select(string = chr, integer = int, part) %>%
      filter(integer > 6 & part == 1) %>% # 6 not 6L to test autocasting
      collect() %>%
      summarize(mean = mean(integer)),
    df1 %>%
      select(string = chr, integer = int) %>%
      filter(integer > 6) %>%
      summarize(mean = mean(integer))
  )
})

test_that("Simple interface for datasets (custom ParquetFileFormat)", {
  ds <- open_dataset(dataset_dir, partitioning = schema(part = uint8()),
                     format = FileFormat$create("parquet", dict_columns = c("chr")))
  expect_equivalent(ds$schema$GetFieldByName("chr")$type, dictionary())
})

test_that("Hive partitioning", {
  ds <- open_dataset(hive_dir, partitioning = hive_partition(other = utf8(), group = uint8()))
  expect_is(ds, "Dataset")
  expect_equivalent(
    ds %>%
      filter(group == 2) %>%
      select(chr, dbl) %>%
      filter(dbl > 7 & dbl < 53) %>%
      collect() %>%
      arrange(dbl),
    df2[1:2, c("chr", "dbl")]
  )
})

test_that("Partitioning inference", {
  # These are the same tests as above, just using the *PartitioningFactory
  ds1 <- open_dataset(dataset_dir, partitioning = "part")
  expect_identical(names(ds1), c(names(df1), "part"))
  expect_equivalent(
    ds1 %>%
      select(string = chr, integer = int, part) %>%
      filter(integer > 6 & part == 1) %>%
      collect() %>%
      summarize(mean = mean(integer)),
    df1 %>%
      select(string = chr, integer = int) %>%
      filter(integer > 6) %>%
      summarize(mean = mean(integer))
  )

  ds2 <- open_dataset(hive_dir)
  expect_identical(names(ds2), c(names(df1), "group", "other"))
  expect_equivalent(
    ds2 %>%
      filter(group == 2) %>%
      select(chr, dbl) %>%
      filter(dbl > 7 & dbl < 53) %>%
      collect() %>%
      arrange(dbl),
    df2[1:2, c("chr", "dbl")]
  )
})

test_that("IPC/Arrow format data", {
  ds <- open_dataset(ipc_dir, partitioning = "part", format = "arrow")
  expect_identical(names(ds), c(names(df1), "part"))
  expect_equivalent(
    ds %>%
      select(string = chr, integer = int, part) %>%
      filter(integer > 6 & part == 3) %>%
      collect() %>%
      summarize(mean = mean(integer)),
    df1 %>%
      select(string = chr, integer = int) %>%
      filter(integer > 6) %>%
      summarize(mean = mean(integer))
  )
})

test_that("Dataset with multiple file formats", {
  skip("https://issues.apache.org/jira/browse/ARROW-7653")
  ds <- open_dataset(children=list(
    open_dataset_factory(dataset_dir, format = "parquet", partitioning = "part"),
    open_dataset_factory(ipc_dir, format = "arrow", partitioning = "part")
  ))
  expect_identical(names(ds), c(names(df1), "part"))
  expect_equivalent(
    ds %>%
      filter(int > 6 & part %in% c(1, 3)) %>%
      select(string = chr, integer = int) %>%
      collect(),
    df1 %>%
      select(string = chr, integer = int) %>%
      filter(integer > 6) %>%
      rbind(., .) # Stack it twice
  )
})

test_that("partitioning = NULL to ignore partition information (but why?)", {
  ds <- open_dataset(hive_dir, partitioning = NULL)
  expect_identical(names(ds), names(df1)) # i.e. not c(names(df1), "group", "other")
})

test_that("filter() with is.na()", {
  ds <- open_dataset(dataset_dir, partitioning = schema(part = uint8()))
  expect_equivalent(
    ds %>%
      select(part, lgl) %>%
      filter(!is.na(lgl), part == 1) %>%
      collect(),
    tibble(part = 1L, lgl = df1$lgl[!is.na(df1$lgl)])
  )
})

test_that("filter() with %in%", {
  ds <- open_dataset(dataset_dir, partitioning = schema(part = uint8()))
  expect_equivalent(
    ds %>%
      select(int, part) %>%
      filter(int %in% c(6, 4, 3, 103, 107), part == 1) %>%
      collect(),
    tibble(int = df1$int[c(3, 4, 6)], part = 1)
  )
})

test_that("filter() on timestamp columns", {
  ds <- open_dataset(dataset_dir, partitioning = schema(part = uint8()))
  expect_equivalent(
    ds %>%
      filter(ts >= lubridate::ymd_hms("2015-05-04 03:12:39")) %>%
      filter(part == 1) %>%
      select(ts) %>%
      collect(),
    df1[5:10, c("ts")],
  )

  # Now with Date
  expect_equivalent(
    ds %>%
      filter(ts >= as.Date("2015-05-04")) %>%
      filter(part == 1) %>%
      select(ts) %>%
      collect(),
    df1[5:10, c("ts")],
  )

  # Now with bare string date
  expect_equivalent(
    ds %>%
      filter(ts >= "2015-05-04") %>%
      filter(part == 1) %>%
      select(ts) %>%
      collect(),
    df1[5:10, c("ts")],
  )
})

test_that("filter() on date32 columns", {
  tmp <- tempfile()
  dir.create(tmp)
  df <- data.frame(date = as.Date(c("2020-02-02", "2020-02-03")))
  write_parquet(df, file.path(tmp, "file.parquet"))

  expect_equal(
    open_dataset(tmp) %>%
      filter(date > as.Date("2020-02-02")) %>%
      collect() %>%
      nrow(),
    1L
  )

  # Also with timestamp scalar
  expect_equal(
    open_dataset(tmp) %>%
      filter(date > lubridate::ymd_hms("2020-02-02 00:00:00")) %>%
      collect() %>%
      nrow(),
    1L
  )
})

test_that("filter scalar validation doesn't crash (ARROW-7772)", {
  expect_error(
    ds %>%
      filter(int == "fff", part == 1) %>%
      collect(),
    "error parsing 'fff' as scalar of type int32"
  )
})

test_that("collect() on Dataset works (if fits in memory)", {
  expect_equal(
    collect(open_dataset(dataset_dir)),
    rbind(
      cbind(df1),
      cbind(df2)
    )
  )
})

test_that("dplyr method not implemented messages", {
  ds <- open_dataset(dataset_dir)
  # This one is more nuanced
  expect_error(
    ds %>% filter(int > 6, dbl > max(dbl)),
    "Filter expression not supported for Arrow Datasets: dbl > max(dbl)\nCall collect() first to pull data into R.",
    fixed = TRUE
  )
  # One explicit test of the full message
  expect_error(
    ds %>% summarize(mean(int)),
    "summarize() is not currently implemented for Arrow Datasets. Call collect() first to pull data into R.",
    fixed = TRUE
  )
  # Helper for everything else
  expect_not_implemented <- function(x) {
    expect_error(x, "is not currently implemented for Arrow Datasets")
  }
  expect_not_implemented(ds %>% arrange(int))
  expect_not_implemented(ds %>% mutate(int = int + 2))
  expect_not_implemented(ds %>% filter(int == 1) %>% summarize(n()))
})

test_that("Dataset and query print methods", {
  ds <- open_dataset(hive_dir)
  expect_output(
    print(ds),
    paste(
      "Dataset",
      "int: int32",
      "dbl: double",
      "lgl: bool",
      "chr: string",
      "fct: dictionary<values=string, indices=int32>",
      "ts: timestamp[us, tz=GMT]",
      "group: int32",
      "other: string",
      "",
      "See $metadata for additional Schema metadata",
      sep = "\n"
    ),
    fixed = TRUE
  )
  expect_is(ds$metadata, "character")
  q <- select(ds, string = chr, lgl, integer = int)
  expect_output(
    print(q),
    paste(
      "Dataset (query)",
      "string: string",
      "lgl: bool",
      "integer: int32",
      "",
      "See $.data for the source Arrow object",
      sep = "\n"
    ),
    fixed = TRUE
  )
  expect_output(
    print(q %>% filter(integer == 6) %>% group_by(lgl)),
    paste(
      "Dataset (query)",
      "string: string",
      "lgl: bool",
      "integer: int32",
      "",
      "* Filter: (int == 6:double)",
      "* Grouped by lgl",
      "See $.data for the source Arrow object",
      sep = "\n"
    ),
    fixed = TRUE
  )
})

expect_scan_result <- function(ds, schm) {
  sb <- ds$NewScan()
  expect_is(sb, "ScannerBuilder")
  expect_equal(sb$schema, schm)

  sb$Project(c("chr", "lgl"))
  sb$Filter(FieldExpression$create("dbl") == 8)
  scn <- sb$Finish()
  expect_is(scn, "Scanner")

  tab <- scn$ToTable()
  expect_is(tab, "Table")

  expect_equivalent(
    as.data.frame(tab),
    df1[8, c("chr", "lgl")]
  )
}

files <- c(
  file.path(dataset_dir, 1, "file1.parquet", fsep = "/"),
  file.path(dataset_dir, 2, "file2.parquet", fsep = "/")
)

test_that("Assembling a Dataset manually and getting a Table", {
  fs <- LocalFileSystem$create()
  selector <- FileSelector$create(dataset_dir, recursive = TRUE)
  partitioning <- DirectoryPartitioning$create(schema(part = double()))

  fmt <- FileFormat$create("parquet")
  factory <- FileSystemDatasetFactory$create(fs, selector, fmt, partitioning = partitioning)
  expect_is(factory, "FileSystemDatasetFactory")

  schm <- factory$Inspect()
  expect_is(schm, "Schema")

  phys_schm <- ParquetFileReader$create(files[1])$GetSchema()
  expect_equal(names(phys_schm), names(df1))
  expect_equal(names(schm), c(names(phys_schm), "part"))

  child <- factory$Finish(schm)
  expect_is(child, "FileSystemDataset")
  expect_is(child$schema, "Schema")
  expect_is(child$format, "ParquetFileFormat")
  expect_equal(names(schm), names(child$schema))
  expect_equivalent(child$files, files)

  ds <- Dataset$create(list(child), schm)
  expect_scan_result(ds, schm)
})

test_that("Assembling multiple DatasetFactories with DatasetFactory", {
  factory1 <- open_dataset_factory(file.path(dataset_dir, 1), format = "parquet")
  expect_is(factory1, "FileSystemDatasetFactory")
  factory2 <- open_dataset_factory(file.path(dataset_dir, 2), format = "parquet")
  expect_is(factory2, "FileSystemDatasetFactory")

  factory <- DatasetFactory$create(children=list(factory1, factory2))
  expect_is(factory, "DatasetFactory")

  schm <- factory$Inspect()
  expect_is(schm, "Schema")

  phys_schm <- ParquetFileReader$create(files[1])$GetSchema()
  expect_equal(names(phys_schm), names(df1))

  ds <- factory$Finish(schm)
  expect_is(ds, "UnionDataset")
  expect_is(ds$schema, "Schema")
  expect_equal(names(schm), names(ds$schema))
  expect_equivalent(map(ds$children, ~.$files), files)

  expect_scan_result(ds, schm)
})
