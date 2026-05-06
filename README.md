# Chronicle Android Preprocessing

## Version

This repository corresponds to version **v1.0**.

---

## Purpose

This repository provides a preprocessing pipeline for transforming **raw Android event log data** (e.g., Chronicle exports) into structured smartphone usage measures.

The script reconstructs:

- **Smartphone 'pickups'**:
  - **Glances**: screen has gone in to an interactive state (turned on for full user interaction, not ambient display or other non-interactive state)
  - **Sessions**: user unlocks their phone after turning it on
- **Application usage episodes**:
  - Specified app is in the foreground of the screen  


The output is designed to feed directly into the companion cleaning repository, but can also be used independently for exploratory or analytical work.

The script is designed for **Chronicle-formatted raw data**, but can be applied to any Android event log dataset with a similar structure (i.e. timestamped events with package names and interaction/event types).

---

## Methodological Basis

The logic implemented in this pipeline is **based on and adapted from**:

> Parry D, Toth R. Extracting meaningful measures of smartphone usage from Android event log data: A methodological primer. Computational Communication Research. 2025;7(1):1. https://doi.org/10.5117/CCR2025.1.8.PARR

That paper provides a structured framework for extracting meaningful smartphone usage metrics from raw Android event logs, including definitions and procedures for identifying: smartphone usage sessions, glances, and app episodes. Thi paper also includes pseudo-code and an example R implementation.

---

## Relationship to the Original Implementation

This script is **adapted from the example implementation provided by Parry & Toth (2025)**, but is not a direct copy.

It has been extended and modified to:

* Work with **Chronicle-style raw data**
* Support a **two-stage pipeline** (preprocessing → cleaning)
* Improve **transparency and flexibility** for applied research use

The core logic for identifying sessions and glances follows the original procedure, while other components have been adapted to better support real-world datasets and downstream processing.

---

## Key Steps

### Background/System Packages Are Retained by Default

In the original procedure, background/system packages are removed early in preprocessing.

In this pipeline, they are **retained by default** and handled later during cleaning.

**Why?**

* **Transparency**
  Cleaning decisions (e.g. removing or truncating “bad apps”) are logged

* **Flexibility**
  Users can define and modify exclusion rules without re-running preprocessing

* **Reproducibility**
  The preprocessing output preserves the full event structure

* **Modularity**

  * Preprocessing → reconstructs behavioral structure
  * Cleaning → applies analytical decisions

An exclusion list derived from the original paper is included and can be enabled in the script if strict replication is desired. Additional system packages from new devices may needed to be added.

---

### Chronicle-Compatible Processing

The script adapts the original logic to Chronicle-style data by:

* Mapping interaction labels to Android-style event types
* Handling Chronicle-specific columns (e.g. app labels, timestamps)
* Producing output compatible with downstream cleaning workflows

---

### Custom App Usage Reconstruction

App usage episodes are reconstructed using Chronicle-style foreground/background logic.

App usage is considered to end when:

* The screen turns off
* The same app moves to the background
* A different app moves to the foreground

---

## Reproducibility

The script is designed to be simple to run and modify.

Key aspects:

* Each file (participant) is processed independently
* No hardcoded assumptions about specific apps
* Optional parameters (e.g. exclusion lists) can be adjusted

---

## To Run

1. Open `run_preprocessing.R`

2. Set:

```r
raw_data <- "path/to/raw_chronicle_csvs"
output_folder <- "path/to/preprocessed_output"
background_packages_file <- "config/background_system_packages.csv"
```

3. Run the script

---

## Optional: Apply Background Package Exclusion

To more closely follow the original Parry & Toth procedure:

* Enable filtering using the provided background package list

By default, this is **disabled**.

This is intentional, as users can handle problematic apps during cleaning.

---

## Output

The script produces:

* One CSV file per participant containing:

  * Session, glance, and app usage events
  * Start and end timestamps
  * Duration (seconds)
  * App package names and labels
  * Session and glance IDs
  * Timezone information

This output is designed to be used with the companion cleaning repository.

---

## Comparison to Parry & Toth Implementation

| Area                 | Parry & Toth (2025)                         | This Repository                                               |
| -------------------- | ------------------------------------------- | ------------------------------------------------------------- |
| Input data           | Generic Android event logs                  | Chronicle-formatted Android event logs (Chronicle-compatible) |
| Event types          | Assumes numeric event types already present | Maps Chronicle interaction labels to Android event types      |
| Background packages  | Removed early in preprocessing              | Retained by default; handled in cleaning                      |
| Session/glance logic | Defined via event sequences (15–18, etc.)   | Same core logic, adapted to Chronicle structure               |
| App episodes         | Derived from event type sequences           | Custom logic based on foreground/background transitions       |
| Output               | Minimal example dataset                     | Structured output for downstream cleaning pipeline            |
| Timezone handling    | Not emphasized                              | Explicit timezone detection and local timestamp formatting    |
| Additional events    | Removed during preprocessing                | Retained where possible for transparency and use in cleaning  |

---

## Notes

* This script assumes familiarity with R and basic data handling
* It is intended for researchers working with **Android event log data**
* Results should always be inspected and validated for your specific dataset

---

## Related Repository

For cleaning and quality control of the preprocessed data, see:

👉

---
