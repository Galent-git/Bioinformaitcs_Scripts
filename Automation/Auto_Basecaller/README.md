
**Automatically initiate basecalling or other processing tasks for sequencing runs upon data arrival.**

This Python script monitors a specified directory for new sequencing run folders. When a new run is detected (and optionally meets readiness criteria), it automatically launches a configured command-line process (e.g., Guppy, Dorado, CCS, QC tools) while respecting concurrency limits.

---

 **Features**
*   ** Directory Monitoring:** Periodically scans a target directory for new run folders.
*   ** Highly Configurable:** Uses a simple `config.ini` file to define watch directories, basecaller paths, arguments, output locations, logging settings, and more.
*   ** Readiness Signal:** Optionally waits for a specific signal file (e.g., `transfer_complete.txt`) within the run folder before processing, ensuring data integrity.
*   ** Automatic Job Launch:** Constructs and executes your basecaller/tool command with run-specific input/output paths.
*   ** Concurrency Control:** Limits the number of simultaneous jobs (`MaxConcurrentJobs`) to avoid overloading system resources.
*   ** State Tracking:** Uses marker files (`.processing`, `.completed`, `.failed`) within each run directory to track status and prevent reprocessing.
*   ** Robust Logging:** Records configuration, detected runs, launched jobs, completion status, and errors to a log file and console.
*   ** Graceful Shutdown:** Handles `Ctrl+C` (SIGINT) and `SIGTERM` to stop launching new jobs cleanly.

---

 **Requirements**
*   Python 3.6+
*   The command-line basecaller or tool you intend to run (e.g., Guppy, Dorado, PacBio `ccs`, etc.) must be installed and accessible in your system's PATH or specified via its full path in the configuration.

---

 **Installation**
1.  Clone this repository or download the script (`basecall_watcher_simple.py`) and the example `config.ini`.
    ```bash
    git clone <your-repo-url>
    cd <your-repo-directory>
    ```
2.  (No Python package dependencies required for the *simplified* version).

---

**Configuration (`config.ini`)**

Create a `config.ini` file (or modify the provided example) with the following sections and keys:

```ini
[Watcher]
# Directory containing the raw sequencing run folders
WatchDirectory = /path/to/raw_data_dropoff

# Optional: Filename that must exist inside a run folder before processing.
# Leave blank or comment out to process immediately upon folder detection (if slot available).
ReadySignalFile = sequencing_summary.txt
# ReadySignalFile =

# How often (in seconds) the script checks for completed jobs and scans for new runs.
CheckInterval = 60

[Basecaller]
# Full path to the basecaller/tool executable.
Executable = /opt/ont/guppy/bin/guppy_basecaller
# Executable = /path/to/dorado/bin/dorado
# Executable = /path/to/pbccs/bin/ccs

# Base directory where output subfolders for each run will be created.
# The script will create <OutputBaseDirectory>/<run_folder_name>/
OutputBaseDirectory = /path/to/basecalled_output

# Path to the basecaller model/configuration file (if required by your tool).
Config = dna_r9.4.1_450bps_hac.cfg
# Config = dna_r10.4.1_e8.2_400bps_hac@v4.2.0 # Example for Dorado

# Arguments passed to the basecaller executable.
# IMPORTANT: Use these placeholders:
#   {input_dir}   - Will be replaced with the absolute path to the detected run folder.
#   {output_dir}  - Will be replaced with the absolute path to the run's specific output folder.
#   {config_path} - Will be replaced with the absolute path to the 'Config' file specified above.
# Add other necessary flags (device, flowcell, kit, threads, etc.) here.
Arguments = --input_path {input_dir} --save_path {output_dir} --config {config_path} --device cuda:0 --records_per_fastq 0 --recursive

# Maximum number of basecaller/tool processes to run concurrently.
MaxConcurrentJobs = 2

[Logging]
# Directory where log files will be stored. Will be created if it doesn't exist.
LogDirectory = /path/to/pipeline_logs

# Name of the log file.
LogFile = basecall_watcher.log

# Logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL). INFO is recommended for production.
LogLevel = INFO

[StateFiles]
# Filenames used as markers within each processed run directory. Keep these simple.
Processing = .basecalling_processing
Completed = .basecalling_completed
Failed = .basecalling_failed
```

**Ensure the user running the script has:**
*   Read permissions for `WatchDirectory` and its subdirectories.
*   Write permissions for `WatchDirectory` subdirectories (to create marker files).
*   Write permissions for `OutputBaseDirectory` (to create output run folders).
*   Write permissions for `LogDirectory`.
*   Execute permissions for the `Executable` defined in the config.

---

**Usage**

1.  Customize your `config.ini` file with the correct paths and parameters for your environment and basecaller/tool.
2.  Run the script from the command line, providing the path to your configuration file:
    ```bash
    python basecall_watcher_simple.py -c /path/to/your/config.ini
    ```
3.  The script will start logging to the console and the specified log file. It will begin its periodic checks.
4.  **To run continuously in the background:** Use tools like `nohup`, `screen`, `tmux`, or set it up as a systemd service.
    *   Example using `nohup`:
        ```bash
        nohup python basecall_watcher_simple.py -c /path/to/your/config.ini > /path/to/pipeline_logs/watcher_stdout.log 2>&1 &
        ```
    *   Example using `screen`:
        ```bash
        screen -S basecaller_watcher # Start a screen session
        python basecall_watcher_simple.py -c /path/to/your/config.ini
        # Press Ctrl+A then D to detach, leaving it running. Use 'screen -r basecaller_watcher' to reattach.
        ```

---

**How It Works**
1.  **Initialization:** Loads configuration, sets up logging.
2.  **Main Loop:** Runs continuously until interrupted (e.g., by `Ctrl+C`).
3.  **Check Active Jobs:** Within the loop (every `CheckInterval` seconds), it polls any running basecaller processes it previously launched to see if they have finished.
4.  **Update State:** If a job finished, it marks the corresponding run directory with `.completed` or `.failed` based on the exit code and removes the `.processing` marker.
5.  **Scan for Pending Runs:** It scans the `WatchDirectory` for subdirectories.
6.  **Check Readiness & Concurrency:** For each subdirectory found:
    *   It checks if it's already marked as `processing`, `completed`, or `failed`. If so, it skips.
    *   If a `ReadySignalFile` is configured, it checks for its presence. If absent, it skips.
    *   It checks if the number of currently active jobs is less than `MaxConcurrentJobs`.
7.  **Launch New Job:** If a run is pending, ready, and a concurrency slot is available, the script:
    *   Creates the `.processing` marker file in the run directory.
    *   Constructs the basecaller command using the template from `config.ini`.
    *   Launches the basecaller command as a non-blocking background process using `subprocess.Popen`.
    *   Stores the process information to monitor later.
8.  **Sleep:** Waits for the `CheckInterval` before repeating the cycle.

---

**State Management**

The script uses empty files (markers) inside each run directory within the `WatchDirectory` to track its status:
*   **(No Marker):** Pending. The script may process this run if it's ready and resources allow.
*   `.basecalling_processing`: The script has launched the basecaller for this run, and it is currently running (or was running when the watcher last checked).
*   `.basecalling_completed`: The basecaller process finished successfully (exit code 0). The script will ignore this directory.
*   `.basecalling_failed`: The basecaller process finished with an error (non-zero exit code) or failed to launch. The script will ignore this directory. Manual intervention may be needed.

---

**Limitations**
*   **Periodic Checks:** This simplified version scans for new runs only every `CheckInterval` seconds. It does not use `watchdog` for near-instant detection.
*   **No Job Termination on Exit:** When the watcher script is stopped (e.g., with `Ctrl+C`), it stops launching *new* jobs, but it **does not** automatically terminate basecaller processes that are already running. These will continue until they complete or are manually stopped.

