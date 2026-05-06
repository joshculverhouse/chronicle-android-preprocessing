# ============================================================================
# Script: run_preprocessing.R
# Purpose:
#   Convert raw Chronicle-style Android event logs into a preprocessed,
#   session-level dataset containing App Usage, Session, and Glance intervals.
#
# Methodological basis:
#   This script is adapted from the example implementation accompanying:
#   Parry & Toth (2025), "Extracting Meaningful Measures of Smartphone Usage
#   from Android Event Log Data: A Methodological Primer".
#
# Key adaptation:
#   Parry & Toth remove background/system packages early in preprocessing.
#   This script retains those packages by default and defers their handling to
#   the companion cleaning pipeline, where removals/truncations can be logged
#   and adjusted by users. Users who want to follow the original procedure more
#   closely can enable background package exclusion below.
#
# Expected input:
#   One or more raw Chronicle Android CSV files containing, at minimum:
#     participant_id
#     interaction_type
#     application_label
#     app_package_name
#     event_timestamp
#     timezone
#
# Output columns:
#   participant_id
#   interaction_type
#   application_label
#   app_package_name
#   event_timestamp
#   start_timestamp
#   stop_timestamp
#   duration_secs
#   timezone
#   source_dataset
#   processing_date
#   processing_version
# ============================================================================

library(tidyverse)
library(lubridate)

# ------------------------ VERSION -------------------------------------------

processing_version <- "v1.0"
processing_date    <- format(Sys.Date(), "%Y-%m-%d")

# ------------------------ USER SETTINGS -------------------------------------

# Folder containing raw Chronicle Android CSV files.
raw_data <- "path/to/raw_chronicle_csvs"

# Folder where preprocessed CSV files should be written.
output_folder <- "path/to/preprocessed_output"

# Optional package exclusion list derived from the Parry & Toth materials.
# This file should contain a column named `pcn` with package names.
background_packages_file <- "background_system_packages.csv"

# Default = FALSE.
# FALSE keeps background/system packages during preprocessing and leaves
# decisions about problematic apps to the downstream cleaning script.
# TRUE removes packages listed in `background_packages_file` during preprocessing,
# which more closely follows the original Parry & Toth example implementation.
apply_background_package_exclusion <- FALSE

# Default = FALSE.
# Nonuse rows represent stop/non-interactive intervals generated internally while
# constructing sessions and glances. Most users should leave these out.
retain_nonuse <- FALSE

# ------------------------ HELPER FUNCTIONS ----------------------------------

check_required_columns <- function(df, file) {
  required_cols <- c(
    "participant_id",
    "interaction_type",
    "application_label",
    "app_package_name",
    "event_timestamp",
    "timezone"
  )
  
  missing_cols <- setdiff(required_cols, names(df))
  
  if (length(missing_cols) > 0) {
    stop(
      "Missing required columns in ", basename(file), ": ",
      paste(missing_cols, collapse = ", ")
    )
  }
}

# Convert raw Chronicle interaction labels to Android-style event type codes.
map_interaction_to_event_type <- function(interaction_type) {
  case_when(
    tolower(interaction_type) == "move to foreground"      ~ "1",
    tolower(interaction_type) == "activity resumed"        ~ "1",
    tolower(interaction_type) == "move to background"      ~ "2",
    tolower(interaction_type) == "activity paused"         ~ "2",
    tolower(interaction_type) == "activity stopped"        ~ "23",
    tolower(interaction_type) == "unknown importance: 23"  ~ "23",
    tolower(interaction_type) == "unknown importance: 15"  ~ "15",
    tolower(interaction_type) == "screen interactive"      ~ "15",
    tolower(interaction_type) == "unknown importance: 16"  ~ "16",
    tolower(interaction_type) == "screen non-interactive"  ~ "16",
    tolower(interaction_type) == "unknown importance: 17"  ~ "17",
    tolower(interaction_type) == "keyguard shown"          ~ "17",
    tolower(interaction_type) == "unknown importance: 18"  ~ "18",
    tolower(interaction_type) == "keyguard hidden"         ~ "18",
    tolower(interaction_type) == "unknown importance: 26"  ~ "26",
    tolower(interaction_type) == "unknown importance: 27"  ~ "27",
    TRUE ~ as.character(interaction_type)
  )
}

# Format event timestamps as local character strings with explicit UTC offset.
fmt_event_timestamp <- function(x, tz) {
  tt <- as.POSIXct(x / 1000, origin = "1970-01-01", tz = "UTC")
  out <- format(tt, "%Y-%m-%d %H:%M:%OS3%z", tz = tz)
  out[is.na(x)] <- NA_character_
  sub("([+-]\\d{2})(\\d{2})$", "\\1:\\2", out)
}

# Format start/stop timestamps to match the downstream cleaning expectations.
fmt_start_stop_timestamp <- function(x, tz) {
  tt_local <- lubridate::with_tz(
    as.POSIXct(x / 1000, origin = "1970-01-01", tz = "UTC"),
    tz
  )
  
  out <- paste0(
    lubridate::month(tt_local), "/",
    lubridate::mday(tt_local), "/",
    lubridate::year(tt_local), " ",
    format(tt_local, "%H:%M:%S")
  )
  
  out[is.na(x)] <- NA_character_
  out
}

load_excluded_packages <- function(background_packages_file,
                                   apply_background_package_exclusion) {
  if (!apply_background_package_exclusion) {
    return(character())
  }
  
  if (!file.exists(background_packages_file)) {
    stop(
      "Background package exclusion was enabled, but the file was not found: ",
      background_packages_file
    )
  }
  
  excluded <- read.csv2(background_packages_file)
  
  if (!"pcn" %in% names(excluded)) {
    stop("The background package file must contain a column named `pcn`.")
  }
  
  excluded %>%
    filter(!is.na(pcn), pcn != "") %>%
    pull(pcn) %>%
    unique()
}

# Build app usage episodes from Chronicle-style foreground/background events.
# An app use starts when an app moves to the foreground / activity resumes.
# It ends at the first subsequent event where:
#   1. the screen becomes non-interactive,
#   2. the same app moves to the background, or
#   3. a different app moves to the foreground.
build_app_usage <- function(df) {
  df <- df %>% arrange(event_timestamp_unix)
  
  n <- nrow(df)
  start_idx <- which(df$event_type == "1" & df$app_package_name != "android")
  
  if (length(start_idx) == 0) {
    return(tibble(
      participant_id = character(),
      app_package_name = character(),
      application_label = character(),
      use_type = character(),
      use_start_timestamp_unix = numeric(),
      use_end_timestamp_unix = numeric(),
      timezone = character(),
      use_duration = numeric()
    ))
  }
  
  out <- vector("list", length(start_idx))
  
  for (k in seq_along(start_idx)) {
    i <- start_idx[k]
    
    start_time <- df$event_timestamp_unix[i]
    start_app  <- df$app_package_name[i]
    end_time <- NA_real_
    
    if (i < n) {
      for (j in (i + 1):n) {
        ev_type <- df$event_type[j]
        ev_app  <- df$app_package_name[j]
        
        is_stop <- (
          ev_type == "16" ||
            (ev_type == "2" & ev_app == start_app) ||
            (ev_type == "1" & ev_app != start_app)
        )
        
        if (is_stop) {
          end_time <- df$event_timestamp_unix[j]
          break
        }
      }
    }
    
    out[[k]] <- tibble(
      participant_id = df$participant_id[i],
      app_package_name = start_app,
      application_label = df$application_label[i],
      use_type = "App Usage",
      use_start_timestamp_unix = start_time,
      use_end_timestamp_unix = end_time,
      timezone = df$timezone[i],
      use_duration = end_time - start_time
    )
  }
  
  bind_rows(out) %>%
    filter(!is.na(use_end_timestamp_unix))
}

# ------------------------ SETUP ---------------------------------------------

excluded_package_names <- load_excluded_packages(
  background_packages_file,
  apply_background_package_exclusion
)

raw_files <- list.files(
  raw_data,
  pattern = "\\.csv$",
  recursive = TRUE,
  full.names = FALSE
)

total_files <- length(raw_files)

if (total_files == 0) {
  stop("No CSV files found in raw_data: ", raw_data)
}

# ------------------------ MAIN LOOP -----------------------------------------

for (i in seq_along(raw_files)) {
  rel_path <- raw_files[i]
  cat("[", i, "/", total_files, "] ", rel_path, "\n", sep = "")
  
  input_file <- file.path(raw_data, rel_path)
  
  original_name <- basename(rel_path)
  base_name <- sub(" Chronicle Android Raw Data.*\\.csv$", "", original_name)
  new_name <- paste0(base_name, " Preprocessed ", processing_date, ".csv")
  output_file <- file.path(output_folder, dirname(rel_path), new_name)
  
  tryCatch({
    # -------------------- READ + STANDARDIZE RAW ----------------------------
    
    raw <- read.csv(input_file)
    check_required_columns(raw, input_file)
    
    raw <- raw %>%
      distinct() %>%
      mutate(
        participant_id = as.character(participant_id),
        event_type = map_interaction_to_event_type(interaction_type),
        event_timestamp_unix = as.numeric(lubridate::ymd_hms(event_timestamp, quiet = TRUE)) * 1000
      ) %>%
      arrange(participant_id, event_timestamp_unix)
    
    # -------------------- DETECT PRIMARY TIMEZONE ---------------------------
    
    tz_counts <- raw %>%
      filter(!is.na(timezone), timezone != "") %>%
      count(timezone, sort = TRUE)
    
    if (nrow(tz_counts) == 0) {
      stop("No valid timezone values found in ", basename(input_file))
    }
    
    primary_tz <- tz_counts$timezone[1]
    
    raw <- raw %>%
      filter(timezone == primary_tz)
    
    cat("  Primary timezone: ", primary_tz, "\n", sep = "")
    
    if (nrow(tz_counts) > 1) {
      cat("  Note: multiple timezones found; filtered to most frequent timezone only.\n")
    }
    
    # -------------------- CREATE SESSION/GLANCE INPUTS ----------------------
    
    pickup_types <- c("1", "15", "16", "17", "18", "26", "27")
    
    filtered_events <- raw %>%
      filter(
        event_type %in% pickup_types,
        !app_package_name %in% excluded_package_names
      )
    
    glance_session_events <- filtered_events %>%
      filter(event_type %in% c("15", "16", "17", "18", "26", "27"))
    
    # -------------------- BUILD GLANCES + SESSIONS --------------------------
    
    if (nrow(glance_session_events) == 0) {
      glances_sessions <- tibble(
        participant_id = character(),
        app_package_name = character(),
        application_label = character(),
        use_type = character(),
        use_start_timestamp_unix = numeric(),
        use_end_timestamp_unix = numeric(),
        timezone = character(),
        use_duration = numeric()
      )
    } else {
      glances_sessions <- glance_session_events %>%
        group_by(participant_id) %>%
        mutate(
          event_type_pre = lag(event_type),
          event_type_nex = lead(event_type),
          use_type = case_when(
            (
              (event_type == "15" & (event_type_pre == "18" | event_type_nex == "18")) |
                (event_type == "16" & (event_type_pre == "17" | event_type_nex == "17")) |
                event_type %in% c("26", "27")
            ) ~ "Session",
            TRUE ~ "Glance"
          ),
          use_state = case_when(
            event_type %in% c("15", "27") ~ "start",
            event_type %in% c("16", "26") ~ "stop",
            TRUE ~ NA_character_
          )
        ) %>%
        filter(!event_type %in% c("17", "18")) %>%
        mutate(
          use_type_pre  = lag(use_type),
          use_state_pre = lag(use_state),
          use_type_nex  = lead(use_type),
          use_state_nex = lead(use_state)
        ) %>%
        filter(
          !(use_type == "Glance"  & use_state == "start" & !(use_type_nex == "Glance"  & use_state_nex == "stop")),
          !(use_type == "Glance"  & use_state == "stop"  & !(use_type_pre == "Glance"  & use_state_pre == "start"))
        ) %>%
        mutate(
          use_type_pre  = lag(use_type),
          use_state_pre = lag(use_state),
          use_type_nex  = lead(use_type),
          use_state_nex = lead(use_state)
        ) %>%
        filter(
          !(use_type == "Session" & use_state == "start" & !(use_type_nex == "Session" & use_state_nex == "stop")),
          !(use_type == "Session" & use_state == "stop"  & !(use_type_pre == "Session" & use_state_pre == "start"))
        ) %>%
        mutate(
          use_end_timestamp_unix = lead(event_timestamp_unix),
          use_duration = use_end_timestamp_unix - event_timestamp_unix
        ) %>%
        ungroup() %>%
        rename(use_start_timestamp_unix = event_timestamp_unix) %>%
        mutate(
          # Stop rows are only needed internally. They can optionally be retained
          # as "nonuse" intervals for auditing, but are excluded by default.
          use_type = case_when(
            use_state == "stop" ~ "nonuse",
            TRUE ~ use_type
          )
        ) %>%
        filter(retain_nonuse | use_type != "nonuse") %>%
        select(
          participant_id,
          app_package_name,
          application_label,
          use_type,
          use_start_timestamp_unix,
          use_end_timestamp_unix,
          timezone,
          use_duration
        )
    }
    
    # -------------------- BUILD APP USAGE EPISODES --------------------------
    
    app_usage <- raw %>%
      group_by(participant_id) %>%
      group_split() %>%
      purrr::map_dfr(build_app_usage)
    
    glances_sessions_episodes <- bind_rows(
      app_usage,
      glances_sessions
    ) %>%
      arrange(participant_id, use_start_timestamp_unix) %>%
      select(
        participant_id,
        app_package_name,
        application_label,
        use_type,
        use_start_timestamp_unix,
        use_end_timestamp_unix,
        timezone,
        use_duration
      )
    
    # -------------------- RAW EXTRA EVENTS ----------------------------------
    
    raw_extras <- raw %>%
      filter(!event_type %in% c(pickup_types, "2", "23")) %>%
      transmute(
        participant_id,
        app_package_name,
        application_label,
        use_type = interaction_type,
        use_start_timestamp_unix = event_timestamp_unix,
        use_end_timestamp_unix = NA_real_,
        timezone,
        use_duration = NA_real_
      )
    
    # -------------------- COMBINE + FORMAT OUTPUT ---------------------------
    
    combined <- bind_rows(
      glances_sessions_episodes,
      raw_extras
    ) %>%
      arrange(participant_id, use_start_timestamp_unix)
    
    file_tz <- combined$timezone[1]
    
    out <- combined %>%
      mutate(
        interaction_type = use_type,
        duration_secs = round(use_duration / 1000, 1),
        event_timestamp = fmt_event_timestamp(use_start_timestamp_unix, file_tz),
        start_timestamp = fmt_start_stop_timestamp(use_start_timestamp_unix, file_tz),
        stop_timestamp  = fmt_start_stop_timestamp(use_end_timestamp_unix, file_tz),
        source_dataset = "ParryToth-adapted",
        processing_date = processing_date,
        processing_version = processing_version
      ) %>%
      select(
        participant_id,
        interaction_type,
        application_label,
        app_package_name,
        event_timestamp,
        start_timestamp,
        stop_timestamp,
        duration_secs,
        timezone,
        source_dataset,
        processing_date,
        processing_version
      ) %>%
      distinct() %>%
      arrange(participant_id, event_timestamp, interaction_type)
    
    # -------------------- WRITE OUTPUT --------------------------------------
    
    dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
    
    write.csv(
      out,
      output_file,
      row.names = FALSE
    )
    
    cat("  ✓ Success\n")
  }, error = function(e) {
    cat("  ✗ Skipped due to error:\n")
    cat("    ", conditionMessage(e), "\n\n")
  })
}
