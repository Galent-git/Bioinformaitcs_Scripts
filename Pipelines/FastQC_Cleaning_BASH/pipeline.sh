#!/usr/bin/env bash

# --- Configurable FASTQ QC, Sampling, Fastp, Post-Trim QC Pipeline ---
#
# Version: 4.1 (Re-adds FastQC on trimmed reads)
#
# Description:
#   Reads settings from a configuration file.
#   Command-line arguments override config file settings.
#   Optionally samples reads (Seqtk), runs initial QC (FastQC),
#   performs trimming/QC with Fastp, runs FastQC on trimmed reads,
#   and aggregates reports (MultiQC).
#
# Usage:
#   ./bashpipe_fastp_qc.sh -1 <r1_fastq> -2 <r2_fastq> -o <output_dir> [-c <config_file>] [-t <threads>] [-T] [-s <num_reads>] [-h]
#
# Arguments:
#   -1 <file>: Path to R1 FASTQ file (Required).
#   -2 <file>: Path to R2 FASTQ file (Required).
#   -o <dir> : Output directory for results (Required).
#   -c <file>: [Optional] Path to configuration file.
#   -t <int> : [Optional] Number of threads (Overrides config, Default: 4).
#   -T       : [Optional] Enable Fastp trimming/QC and subsequent FastQC run (Overrides config, Default: false).
#   -s <int> : [Optional] Sample <num_reads> read pairs (Overrides config, Default: 0=all).
#   -h       : Display this help message.
#
# Config File Format (Example: pipeline.conf):
#   THREADS=8
#   ENABLE_FASTP=true
#   SAMPLE_READS=100000
#   FASTP_EXTRA_PARAMS="--length_required 50 -q 20"
#   FASTQC_CMD=fastqc
#   MULTIQC_CMD=multiqc
#   SEQTK_CMD=seqtk
#   FASTP_CMD=fastp
#
# Dependencies: fastqc, multiqc, seqtk (if -s used), fastp (if -T used)

# --- Strict Mode & Error Handling ---
set -e
set -u
set -o pipefail

# --- Function Definitions ---
usage() {
  echo "Usage: $0 -1 <r1_fastq> -2 <r2_fastq> -o <output_dir> [-c <config_file>] [-t <threads>] [-T] [-s <num_reads>] [-h]"
  echo "  -1 <file>: Path to R1 FASTQ file (Required)."
  echo "  -2 <file>: Path to R2 FASTQ file (Required)."
  echo "  -o <dir> : Output directory for results (Required)."
  echo "  -c <file>: [Optional] Path to configuration file."
  echo "  -t <int> : [Optional] Number of threads (Overrides config, Default: 4)."
  echo "  -T       : [Optional] Enable Fastp trimming/QC & post-trim FastQC (Overrides config, Default: false)."
  echo "  -s <int> : [Optional] Sample <num_reads> read pairs (Overrides config, Default: 0=all)."
  echo "  -h       : Display this help message."
  exit 1
}

load_config() {
  local config_file="$1"
  if [ ! -f "${config_file}" ]; then
    echo "WARN: Configuration file '${config_file}' not found. Using defaults and command-line args."
    return
  fi
  echo "INFO: Loading configuration from ${config_file}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "$line" || "$line" =~ ^# ]]; then
      continue
    fi
    if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]]; then
       eval "$(printf 'export %s' "$line")"
    else
       echo "WARN: Ignoring invalid line in config file: $line"
    fi
  done < "${config_file}"
  echo "INFO: Configuration loaded."
}

# --- Initial Default Values ---
THREADS=4
ENABLE_FASTP=false
SAMPLE_READS=0
CONFIG_FILE=""
FASTQC_CMD="fastqc"
MULTIQC_CMD="multiqc"
SEQTK_CMD="seqtk"
FASTP_CMD="fastp"
FASTP_EXTRA_PARAMS=""

# --- Argument Parsing ---
cmd_r1_file=""
cmd_r2_file=""
cmd_output_dir=""
cmd_config_file=""
cmd_threads=""
cmd_enable_fastp="NOT_SET"
cmd_sample_reads=""

while getopts "1:2:o:c:t:Ts:h" opt; do
  case $opt in
    1) cmd_r1_file="${OPTARG}" ;;
    2) cmd_r2_file="${OPTARG}" ;;
    o) cmd_output_dir="${OPTARG}" ;;
    c) cmd_config_file="${OPTARG}" ;;
    t) cmd_threads="${OPTARG}" ;;
    T) cmd_enable_fastp=true ;;
    s) cmd_sample_reads="${OPTARG}" ;;
    h) usage ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

# --- Load Configuration File ---
if [ -n "${cmd_config_file}" ]; then
  load_config "${cmd_config_file}"
fi

# --- Finalize Configuration ---
R1_FILE="${cmd_r1_file:-${R1_FILE:-}}"
R2_FILE="${cmd_r2_file:-${R2_FILE:-}}"
OUTPUT_DIR="${cmd_output_dir:-${OUTPUT_DIR:-}}"
THREADS="${cmd_threads:-${THREADS:-4}}"
SAMPLE_READS="${cmd_sample_reads:-${SAMPLE_READS:-0}}"

if [ "$cmd_enable_fastp" != "NOT_SET" ]; then
  ENABLE_FASTP="$cmd_enable_fastp"
elif [ -z "${ENABLE_FASTP:-}" ]; then
    ENABLE_FASTP=false
fi
if [[ "$(echo "${ENABLE_FASTP}" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
    ENABLE_FASTP=true
else
    ENABLE_FASTP=false
fi

# --- Validate Required Arguments ---
if [ -z "${R1_FILE}" ] || [ -z "${R2_FILE}" ] || [ -z "${OUTPUT_DIR}" ]; then
  echo "Error: R1 file (-1), R2 file (-2), and Output directory (-o) are required."
  usage
fi
if [ ! -f "${R1_FILE}" ]; then
  echo "Error: Input R1 file '${R1_FILE}' not found or is not a regular file."
  exit 1
fi
if [ ! -f "${R2_FILE}" ]; then
  echo "Error: Input R2 file '${R2_FILE}' not found or is not a regular file."
  exit 1
fi
if [[ "${SAMPLE_READS}" -lt 0 ]]; then
    echo "Error: Sample size (-s or config SAMPLE_READS) cannot be negative."
    usage
fi

# --- Dependency Checks ---
command -v "${FASTQC_CMD}" >/dev/null 2>&1 || { echo "Error: fastqc command ('${FASTQC_CMD}') not found in PATH." >&2; exit 1; }
command -v "${MULTIQC_CMD}" >/dev/null 2>&1 || { echo "Error: multiqc command ('${MULTIQC_CMD}') not found in PATH." >&2; exit 1; }
if [[ "${SAMPLE_READS}" -gt 0 ]]; then
  command -v "${SEQTK_CMD}" >/dev/null 2>&1 || { echo "Error: seqtk command ('${SEQTK_CMD}') not found. Required for sampling." >&2; exit 1; }
fi
if [ "${ENABLE_FASTP}" = true ]; then
  command -v "${FASTP_CMD}" >/dev/null 2>&1 || { echo "Error: fastp command ('${FASTP_CMD}') not found in PATH." >&2; exit 1; }
fi

# --- Setup Output Directories --- ## UPDATED DIRECTORY STRUCTURE ##
SAMPLE_DIR="${OUTPUT_DIR}/0_Sampled_Reads"
RAW_FASTQC_DIR="${OUTPUT_DIR}/1_Raw_FastQC"
TRIM_DIR="${OUTPUT_DIR}/2_Trimmed_Reads"        # Fastp trimmed FASTQs
TRIM_FASTQC_DIR="${OUTPUT_DIR}/3_Trimmed_FastQC" # FastQC reports for trimmed reads (Re-added)
FASTP_REPORT_DIR="${OUTPUT_DIR}/4_Fastp_Reports"  # Fastp HTML/JSON reports (Renumbered)
MULTIQC_DIR="${OUTPUT_DIR}/5_MultiQC_Report"   # Final aggregated report (Renumbered)
LOG_DIR="${OUTPUT_DIR}/logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/pipeline_${TIMESTAMP}.log"

# --- Logging Setup ---
mkdir -p "${RAW_FASTQC_DIR}" # For initial FastQC
mkdir -p "${LOG_DIR}"        # For log file
[ "${SAMPLE_READS}" -gt 0 ] && mkdir -p "${SAMPLE_DIR}" # For sampling
# Create Fastp/Trim related dirs if enabled (Do this later, just before needed)

# Redirect *after* creating essential log dir
exec > >(tee -a "${LOG_FILE}") 2>&1

# --- Print Effective Configuration ---
echo "--- Pipeline Start: $(date) ---"
echo "Input R1 File: ${R1_FILE}"
echo "Input R2 File: ${R2_FILE}"
echo "Output Directory: ${OUTPUT_DIR}"
echo "Threads: ${THREADS}"
echo "Enable Sampling: $(if [[ $SAMPLE_READS -gt 0 ]]; then echo Yes \(N=${SAMPLE_READS}\); else echo No; fi)"
echo "Enable Fastp & Post-Trim QC: ${ENABLE_FASTP}" # Updated description
echo "Log File: ${LOG_FILE}"
echo "Effective Commands:"
echo "  FastQC: ${FASTQC_CMD}"
echo "  MultiQC: ${MULTIQC_CMD}"
[ "${SAMPLE_READS}" -gt 0 ] && echo "  Seqtk: ${SEQTK_CMD}"
[ "${ENABLE_FASTP}" = true ] && echo "  Fastp: ${FASTP_CMD}"
[ "${ENABLE_FASTP}" = true ] && [ -n "${FASTP_EXTRA_PARAMS}" ] && echo "  Fastp Extra Params: ${FASTP_EXTRA_PARAMS}"
echo "---------------------------------"

echo "INFO: Starting Configurable Pipeline for specified pair..."

# --- Determine files to process (Raw or Sampled) ---
qc_input_files=()
fastp_input_r1=""
fastp_input_r2=""

current_r1="${R1_FILE}"
current_r2="${R2_FILE}"
base_name_r1=$(basename "${R1_FILE}")
clean_base_name=$(echo "$base_name_r1" | sed -E 's/[\._]([Rr]1|1)[\._]?[^\.]*(\.fastq\.gz|\.fq\.gz|\.fastq|\.fq)$//; s/(\.fastq\.gz|\.fq\.gz|\.fastq|\.fq)$//')
[ -z "${clean_base_name}" ] && clean_base_name="${base_name_r1%.*}"

if [[ "${SAMPLE_READS}" -gt 0 ]]; then
    echo "INFO: Sampling ${SAMPLE_READS} pairs for ${clean_base_name}..."
    sampled_r1="${SAMPLE_DIR}/${clean_base_name}_R1.sampled.fq.gz"
    sampled_r2="${SAMPLE_DIR}/${clean_base_name}_R2.sampled.fq.gz"
    # No need for mkdir here, already done above

    sampling_seed=11
    cat_cmd1="cat"; [[ "$R1_FILE" == *.gz ]] && cat_cmd1="zcat"
    cat_cmd2="cat"; [[ "$R2_FILE" == *.gz ]] && cat_cmd2="zcat"

    echo "DEBUG: Sampling R1: $cat_cmd1 \"${R1_FILE}\" | \"${SEQTK_CMD}\" sample -s\"${sampling_seed}\" - \"${SAMPLE_READS}\" | gzip > \"${sampled_r1}\""
    $cat_cmd1 "${R1_FILE}" | "${SEQTK_CMD}" sample -s"${sampling_seed}" - "${SAMPLE_READS}" | gzip > "${sampled_r1}"
    exit_code_r1=$?
    echo "DEBUG: Sampling R2: $cat_cmd2 \"${R2_FILE}\" | \"${SEQTK_CMD}\" sample -s\"${sampling_seed}\" - \"${SAMPLE_READS}\" | gzip > \"${sampled_r2}\""
    $cat_cmd2 "${R2_FILE}" | "${SEQTK_CMD}" sample -s"${sampling_seed}" - "${SAMPLE_READS}" | gzip > "${sampled_r2}"
    exit_code_r2=$?

    if [ $exit_code_r1 -ne 0 ] || [ $exit_code_r2 -ne 0 ] || [ ! -s "${sampled_r1}" ] || [ ! -s "${sampled_r2}" ]; then
         echo "ERROR: Sampling failed for ${clean_base_name}. Check seqtk command, disk space, and file integrity."
         rm -f "${sampled_r1}" "${sampled_r2}"
         exit 1
    fi
    echo "INFO: Sampling complete. Output: ${sampled_r1}, ${sampled_r2}"
    current_r1="${sampled_r1}"
    current_r2="${sampled_r2}"
fi

# Populate arrays for initial FastQC
qc_input_files+=("${current_r1}")
qc_input_files+=("${current_r2}")
# Set variables for potential Fastp run
fastp_input_r1="${current_r1}"
fastp_input_r2="${current_r2}"

# --- Run FastQC on Input Reads (Raw or Sampled) ---
if [ ${#qc_input_files[@]} -gt 0 ]; then
    echo "INFO: Running FastQC (${FASTQC_CMD}) on input reads..."
    "${FASTQC_CMD}" --outdir "${RAW_FASTQC_DIR}" --threads "${THREADS}" "${qc_input_files[@]}"
    echo "INFO: Input FastQC finished."
else
    echo "WARN: No input files identified for initial FastQC."
fi

# --- Optional: Run Fastp and subsequent FastQC ---
if [ "${ENABLE_FASTP}" = true ]; then
  echo "INFO: Fastp enabled. Processing pair for ${clean_base_name}..."

  # Create output directories for this section just before use
  mkdir -p "${TRIM_DIR}"
  mkdir -p "${FASTP_REPORT_DIR}"
  mkdir -p "${TRIM_FASTQC_DIR}" # Create dir for trimmed FastQC output

  # Define output file paths for Fastp
  r1_trimmed_out="${TRIM_DIR}/${clean_base_name}_R1.trimmed.fq.gz"
  r2_trimmed_out="${TRIM_DIR}/${clean_base_name}_R2.trimmed.fq.gz"
  fastp_html_report="${FASTP_REPORT_DIR}/${clean_base_name}.fastp.html"
  fastp_json_report="${FASTP_REPORT_DIR}/${clean_base_name}.fastp.json"

  echo "INFO: Running Fastp (${FASTP_CMD}) on ${clean_base_name}..."
  echo "DEBUG: Input R1: ${fastp_input_r1}" # ... [Debug lines kept for brevity]
  echo "DEBUG: Output R1: ${r1_trimmed_out}" # ...
  echo "DEBUG: JSON Report: ${fastp_json_report}" # ...
  [ -n "${FASTP_EXTRA_PARAMS}" ] && echo "DEBUG: Extra Params: ${FASTP_EXTRA_PARAMS}"

  # Execute Fastp command
  eval "${FASTP_CMD}" \
    --in1 "'${fastp_input_r1}'" \
    --in2 "'${fastp_input_r2}'" \
    --out1 "'${r1_trimmed_out}'" \
    --out2 "'${r2_trimmed_out}'" \
    --html "'${fastp_html_report}'" \
    --json "'${fastp_json_report}'" \
    --thread "${THREADS}" \
    ${FASTP_EXTRA_PARAMS:-}

   fastp_exit_code=$?
   if [ ${fastp_exit_code} -ne 0 ]; then
        echo "ERROR: Fastp failed for ${clean_base_name} with exit code ${fastp_exit_code}. Check Fastp logs/output."
        exit 1
    else
         echo "INFO: Fastp finished successfully for ${clean_base_name}."

         # --- Run FastQC on Trimmed Reads (Fastp Output) --- ## RE-ADDED THIS BLOCK ##
         trimmed_files_for_qc=()
         # Check if trimmed files exist and are not empty before adding
         if [ -s "${r1_trimmed_out}" ]; then trimmed_files_for_qc+=("${r1_trimmed_out}"); fi
         if [ -s "${r2_trimmed_out}" ]; then trimmed_files_for_qc+=("${r2_trimmed_out}"); fi

         if [ ${#trimmed_files_for_qc[@]} -gt 0 ]; then
             echo "INFO: Running FastQC (${FASTQC_CMD}) on trimmed reads (Fastp output)..."
             "${FASTQC_CMD}" --outdir "${TRIM_FASTQC_DIR}" --threads "${THREADS}" "${trimmed_files_for_qc[@]}"
             echo "INFO: Trimmed FastQC finished."
         else
             # This might happen if Fastp filtered out ALL reads
             echo "WARN: No successfully trimmed paired files found from Fastp for subsequent QC."
         fi
    fi

fi # End of ENABLE_FASTP block

# --- Run MultiQC ---
echo "INFO: Running MultiQC (${MULTIQC_CMD}) to aggregate all QC reports..."
# MultiQC will scan OUTPUT_DIR and find Raw_FastQC, Trimmed_FastQC, and Fastp reports
"${MULTIQC_CMD}" "${OUTPUT_DIR}" --outdir "${MULTIQC_DIR}" --filename "multiqc_report.html" --title "QC Report: ${clean_base_name}" --force
echo "INFO: MultiQC finished."

# --- Completion --- ## UPDATED MESSAGES ##
echo "---------------------------------"
echo "INFO: Pipeline Completed Successfully!"
[ "${SAMPLE_READS}" -gt 0 ] && echo "Sampled reads location (if enabled): ${SAMPLE_DIR}"
echo "Input reads FastQC reports: ${RAW_FASTQC_DIR}"
if [ "${ENABLE_FASTP}" = true ]; then
  echo "Trimmed reads location (Fastp output): ${TRIM_DIR}"
  echo "Fastp HTML/JSON reports: ${FASTP_REPORT_DIR}"
  echo "Trimmed reads FastQC reports: ${TRIM_FASTQC_DIR}" # Re-added this line
fi
echo "MultiQC HTML report: ${MULTIQC_DIR}/multiqc_report.html"
echo "Detailed log: ${LOG_FILE}"
echo "--- Pipeline End: $(date) ---"

exit 0
