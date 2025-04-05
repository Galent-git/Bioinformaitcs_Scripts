#!/usr/bin/env python3

import sys
import os
import time
import logging
import argparse
import configparser
import subprocess
from pathlib import Path
import signal # For graceful shutdown

# --- Global Variables ---
CONFIG = None
ACTIVE_PROCESSES = {} # Dict mapping run_path_str -> Popen object
MARKER_PROCESSING = ".processing"
MARKER_COMPLETED = ".completed"
MARKER_FAILED = ".failed"
SHUTDOWN_REQUESTED = False

# --- Logging Setup ---
def setup_logging(log_dir_str, log_file, level_str):
    """Configures logging."""
    log_level = getattr(logging, level_str.upper(), logging.INFO)
    log_dir = Path(log_dir_str)
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / log_file

    logging.basicConfig(
        level=log_level,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        handlers=[
            logging.FileHandler(log_path),
            logging.StreamHandler(sys.stdout)
        ]
    )
    # Use a distinct logger name
    logger = logging.getLogger("BasecallWatcher")
    logger.info("Logging initialized.")
    logger.info(f"Log file: {log_path}")
    return logger

# --- Configuration Loading ---
def load_config(config_path):
    """Loads and validates configuration."""
    config_file = Path(config_path)
    if not config_file.is_file():
        print(f"ERROR: Configuration file not found at {config_file}", file=sys.stderr)
        sys.exit(1)

    parser = configparser.ConfigParser(interpolation=None)
    parser.read(config_file)
    config = {section: dict(parser.items(section)) for section in parser.sections()}

    # Basic Validation (simplified check for essential keys)
    required = {
        ('Watcher', 'watchdirectory'), ('Watcher', 'checkinterval'),
        ('Basecaller', 'executable'), ('Basecaller', 'outputbasedirectory'),
        ('Basecaller', 'config'), ('Basecaller', 'arguments'), ('Basecaller', 'maxconcurrentjobs'),
        ('Logging', 'logdirectory'), ('Logging', 'logfile'), ('Logging', 'loglevel'),
        ('StateFiles', 'processing'), ('StateFiles', 'completed'), ('StateFiles', 'failed')
    }
    missing = False
    for section, key in required:
        if not config.get(section, {}).get(key):
            print(f"ERROR: Missing or empty required key '{key}' in section [{section}].", file=sys.stderr)
            missing = True
    if missing:
        sys.exit(1)

    # Set global marker filenames from config
    global MARKER_PROCESSING, MARKER_COMPLETED, MARKER_FAILED
    MARKER_PROCESSING = config['StateFiles']['processing']
    MARKER_COMPLETED = config['StateFiles']['completed']
    MARKER_FAILED = config['StateFiles']['failed']

    print("Configuration loaded successfully.") # Log before logger setup
    return config

# --- State Management ---
def get_run_state(run_path: Path):
    """Checks for marker files to determine the run's state."""
    if (run_path / MARKER_PROCESSING).exists():
        return "processing"
    if (run_path / MARKER_COMPLETED).exists():
        return "completed"
    if (run_path / MARKER_FAILED).exists():
        return "failed"
    # Check if it's actually a directory before calling it pending
    if run_path.is_dir():
        return "pending"
    return "unknown" # Not a directory or no markers

def mark_run_state(run_path: Path, state_marker: str, logger: logging.Logger):
    """Creates a marker file and removes others."""
    markers_to_remove = [MARKER_PROCESSING, MARKER_COMPLETED, MARKER_FAILED]
    try:
        # Remove the target marker from the removal list if it's being set
        if state_marker and state_marker in markers_to_remove:
            markers_to_remove.remove(state_marker)
            (run_path / state_marker).touch(exist_ok=True)
            logger.debug(f"Marked {run_path.name} with {state_marker}")

        # Remove other markers
        for marker in markers_to_remove:
            marker_path = run_path / marker
            if marker_path.exists():
                try:
                    marker_path.unlink()
                    logger.debug(f"Removed marker {marker} for {run_path.name}")
                except OSError as e:
                    logger.warning(f"Could not remove marker {marker} for {run_path.name}: {e}")

    except OSError as e:
        logger.warning(f"Could not update state marker for {run_path.name}: {e}")

# --- Basecalling Logic ---
def launch_basecaller(run_path: Path, logger: logging.Logger):
    """Constructs and launches the basecalling command. Returns Popen object or None."""
    global CONFIG, ACTIVE_PROCESSES

    run_name = run_path.name
    output_base_dir = Path(CONFIG['Basecaller']['outputbasedirectory'])
    output_run_dir = output_base_dir / run_name
    basecaller_exe = Path(CONFIG['Basecaller']['executable'])
    basecaller_config = Path(CONFIG['Basecaller']['config'])
    basecaller_args_template = CONFIG['Basecaller']['arguments']

    if not basecaller_exe.is_file():
        logger.error(f"Basecaller executable not found: {basecaller_exe}")
        mark_run_state(run_path, MARKER_FAILED, logger)
        return None

    try:
        output_run_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Ensured output directory exists: {output_run_dir}")
    except OSError as e:
        logger.error(f"Failed to create output directory {output_run_dir}: {e}")
        mark_run_state(run_path, MARKER_FAILED, logger)
        return None

    # Format arguments using pathlib for resolved paths
    try:
        replacements = {
            "input_dir": str(run_path.resolve()),
            "output_dir": str(output_run_dir.resolve()),
            "config_path": str(basecaller_config.resolve())
        }
        formatted_args = basecaller_args_template.format(**replacements)
    except KeyError as e:
        logger.error(f"Missing placeholder {e} in Basecaller Arguments template.")
        mark_run_state(run_path, MARKER_FAILED, logger)
        return None

    command = [str(basecaller_exe)] + formatted_args.split()
    logger.info(f"Attempting to launch basecalling for run: {run_name}")
    logger.info(f"Command: {' '.join(command)}")

    # Mark as processing *before* launch
    mark_run_state(run_path, MARKER_PROCESSING, logger)

    try:
        # Use Popen for non-blocking execution. Redirect stdout/stderr if desired (e.g., to files)
        # For simplicity here, let them inherit or go to PIPE if needed later.
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ACTIVE_PROCESSES[str(run_path)] = process
        logger.info(f"Successfully launched basecaller for {run_name}. PID: {process.pid}")
        return process

    except (FileNotFoundError, OSError, Exception) as e:
        logger.error(f"Failed to launch basecaller for {run_name}: {e}")
        mark_run_state(run_path, MARKER_FAILED, logger)
        # Remove from active if somehow added before exception
        ACTIVE_PROCESSES.pop(str(run_path), None)
        return None

# --- Main Loop Logic ---
def check_and_launch_jobs(logger: logging.Logger):
    """Checks active jobs, scans for pending runs, and launches new jobs."""
    global ACTIVE_PROCESSES, CONFIG

    max_jobs = int(CONFIG['Basecaller']['maxconcurrentjobs'])
    watch_dir = Path(CONFIG['Watcher']['watchdirectory'])
    ready_signal = CONFIG['Watcher'].get('readysignalfile') # Optional

    # --- 1. Check Active Processes ---
    completed_this_cycle = []
    for run_path_str, process in list(ACTIVE_PROCESSES.items()):
        run_path = Path(run_path_str)
        return_code = process.poll() # Check if process finished

        if return_code is not None:
            completed_this_cycle.append(run_path_str)
            if return_code == 0:
                logger.info(f"Basecalling completed successfully for {run_path.name} (PID: {process.pid}).")
                mark_run_state(run_path, MARKER_COMPLETED, logger)
            else:
                logger.error(f"Basecalling failed for {run_path.name} (PID: {process.pid}, Exit Code: {return_code}).")
                mark_run_state(run_path, MARKER_FAILED, logger)

    # Remove completed processes from active dict
    for run_path_str in completed_this_cycle:
        ACTIVE_PROCESSES.pop(run_path_str, None)

    # --- 2. Scan Watch Directory for Pending Runs & Launch ---
    # Check available slots *after* polling completed jobs
    available_slots = max_jobs - len(ACTIVE_PROCESSES)
    if available_slots <= 0:
        logger.debug("Concurrency limit reached. No new jobs will be launched.")
        return # No point scanning if no slots

    launched_count = 0
    try:
        # Iterate through items in watch_dir
        for item_path in watch_dir.iterdir():
            if available_slots <= 0: # Check again in case we filled up
                break

            # Basic check: Is it a directory and not hidden?
            if not item_path.is_dir() or item_path.name.startswith('.'):
                continue

            run_path = item_path
            run_name = run_path.name
            run_path_str = str(run_path)

            # Is it already being processed or completed/failed?
            current_state = get_run_state(run_path)
            if current_state != "pending":
                # Log if it's marked 'processing' but not in our active dict (e.g., after restart)
                if current_state == "processing" and run_path_str not in ACTIVE_PROCESSES:
                    logger.warning(f"Run {run_name} has '{MARKER_PROCESSING}' marker but is not tracked as active. Manual check advised.")
                continue # Skip non-pending runs

            # Is it ready? (Signal file check)
            if ready_signal:
                signal_file_path = run_path / ready_signal
                if not signal_file_path.is_file():
                    logger.debug(f"Run {run_name} is pending, waiting for signal file: {ready_signal}")
                    continue # Not ready yet

                logger.debug(f"Signal file '{ready_signal}' found for {run_name}.")

            # We have a pending, ready run, and slots MIGHT be available
            logger.info(f"Found pending and ready run: {run_name}. Checking concurrency.")

            if len(ACTIVE_PROCESSES) < max_jobs:
                 if launch_basecaller(run_path, logger):
                     launched_count += 1
                     available_slots -= 1 # Decrement available slots for this cycle
                 else:
                     # Launch failed, state already marked FAILED by launch_basecaller
                     logger.error(f"Failed to initiate basecalling for {run_name}. See previous errors.")
            else:
                 # This condition should technically be caught by available_slots check earlier,
                 # but good for safety.
                 logger.debug(f"Concurrency limit reached before launching {run_name}.")
                 break # Stop scanning if limit reached

        if launched_count > 0:
            logger.info(f"Launched {launched_count} new basecalling job(s) this cycle.")

    except FileNotFoundError:
        logger.error(f"Watch directory {watch_dir} not found during scan.")
    except Exception as e:
        logger.error(f"Error scanning watch directory {watch_dir}: {e}", exc_info=True)


# --- Signal Handling for Graceful Shutdown ---
def handle_shutdown_signal(signum, frame):
    global SHUTDOWN_REQUESTED
    logger = logging.getLogger("BasecallWatcher")
    if not SHUTDOWN_REQUESTED:
        logger.info(f"Shutdown signal ({signal.Signals(signum).name}) received. Stopping new job launches and waiting for observer...")
        SHUTDOWN_REQUESTED = True
    else:
        logger.warning("Multiple shutdown signals received. Forcing exit.")
        sys.exit(1)

# --- Main Execution ---
if __name__ == "__main__":
    # Must load config first to get logger settings
    parser = argparse.ArgumentParser(description="Automated Basecalling Watcher (Simple)")
    parser.add_argument("-c", "--config", required=True, help="Path to the configuration INI file.")
    args = parser.parse_args()

    CONFIG = load_config(args.config)
    logger = setup_logging(
        CONFIG['Logging']['logdirectory'],
        CONFIG['Logging']['logfile'],
        CONFIG['Logging']['loglevel']
    )

    watch_dir = Path(CONFIG['Watcher']['watchdirectory'])
    check_interval = int(CONFIG['Watcher']['checkinterval'])

    if not watch_dir.is_dir():
        logger.critical(f"Watch directory does not exist or is not a directory: {watch_dir}")
        sys.exit(1)

    # Setup signal handlers
    signal.signal(signal.SIGINT, handle_shutdown_signal)  # Ctrl+C
    signal.signal(signal.SIGTERM, handle_shutdown_signal) # kill command

    logger.info(f"Starting watcher on directory: {watch_dir}")
    logger.info(f"Checking for jobs every {check_interval} seconds.")
    if CONFIG['Watcher'].get('readysignalfile'):
        logger.info(f"Waiting for signal file: {CONFIG['Watcher']['readysignalfile']}")
    logger.info(f"Maximum concurrent jobs: {CONFIG['Basecaller']['maxconcurrentjobs']}")

    # Note: We removed watchdog here for simplification.
    # This means new directories are only detected during the periodic check.
    # If near-instant detection is critical, watchdog should be added back.
    logger.info("Running periodic checks. (Watchdog observer not used in this simplified version).")

    try:
        while not SHUTDOWN_REQUESTED:
            check_and_launch_jobs(logger)
            # Sleep for the interval, but break early if shutdown requested
            for _ in range(check_interval):
                if SHUTDOWN_REQUESTED:
                    break
                time.sleep(1)
    except Exception as e:
        logger.critical(f"An unexpected error occurred in the main loop: {e}", exc_info=True)
    finally:
        logger.info("Watcher loop finished.")
        # Note: This simplified version doesn't actively manage/kill running basecaller processes on exit.
        # They will continue running unless terminated externally.
        logger.info("Existing basecaller processes will continue to run.")
        logger.info("Basecall watcher finished.")
