Bash FASTQ QC Pipeline (using Fastp)

A flexible Bash script for performing quality control, optional sampling, and trimming on paired-end FASTQ data using standard bioinformatics tools.
Description

This pipeline provides a configurable workflow for assessing and processing paired-end FASTQ files. It performs the following steps:

    Initial QC: Runs FastQC on the input reads (raw or sampled) to assess initial quality.

    Optional Sampling: If specified, subsamples reads using Seqtk while maintaining pairing (using a fixed seed for reproducibility).

    Trimming & Filtering: If enabled (-T), uses Fastp to perform adapter trimming (auto-detection), quality filtering, length filtering, and other cleaning operations. Generates Fastp's standard HTML/JSON reports.

    Post-Trim QC: If trimming was enabled, runs FastQC again on the trimmed paired reads produced by Fastp for comparison.

    Report Aggregation: Runs MultiQC to compile results from the initial FastQC run, the Fastp run, and the post-trim FastQC run into a single summary HTML report.

The pipeline is configured via command-line arguments, which can override default settings specified in an optional configuration file.
Features

    Paired-end FASTQ processing.

    Optional read sampling with Seqtk.

    Initial quality assessment with FastQC.

    Adapter/quality trimming and filtering using Fastp (modern, fast).

    Optional post-trimming quality assessment with FastQC.

    Comprehensive reporting using MultiQC (aggregates FastQC and Fastp results).

    Configuration via command-line flags and optional pipeline.conf file.

    Parameter override precedence (Command-line > Config File > Script Defaults).

    Detailed logging for traceability.

    Basic error handling and dependency checks.

Dependencies

    Bash (v4.0+ recommended for eval usage in config loading)

    FastQC (e.g., v0.11.9+)

    Fastp (e.g., v0.23.+)

    Seqtk (Required only if using sampling -s)

    MultiQC (e.g., v1.10+)

    Standard Unix utilities (sed, basename, date, tee, mkdir, rm, cat/zcat, gzip).

Installation via Conda is recommended:

      
conda create -n qc_env -c bioconda fastqc fastp seqtk multiqc
conda activate qc_env

    

IGNORE_WHEN_COPYING_START
Use code with caution.Bash
IGNORE_WHEN_COPYING_END
Installation

    Clone the repository or download the script (e.g., bashpipe_fastp_qc.sh).

          
    # git clone <your-repo-url>
    # cd <your-repo-directory>

        

    IGNORE_WHEN_COPYING_START

Use code with caution.Bash
IGNORE_WHEN_COPYING_END

Make the script executable:

      
chmod +x bashpipe_fastp_qc.sh

    

IGNORE_WHEN_COPYING_START

    Use code with caution.Bash
    IGNORE_WHEN_COPYING_END

Usage

      
./bashpipe_fastp_qc.sh -h

    

IGNORE_WHEN_COPYING_START
Use code with caution.Bash
IGNORE_WHEN_COPYING_END

      
Usage: ./bashpipe_fastp_qc.sh -1 <r1_fastq> -2 <r2_fastq> -o <output_dir> [-c <config_file>] [-t <threads>] [-T] [-s <num_reads>] [-h]
  -1 <file>: Path to R1 FASTQ file (Required).
  -2 <file>: Path to R2 FASTQ file (Required).
  -o <dir> : Output directory for results (Required).
  -c <file>: [Optional] Path to configuration file.
  -t <int> : [Optional] Number of threads (Overrides config, Default: 4).
  -T       : [Optional] Enable Fastp trimming/QC & post-trim FastQC (Overrides config, Default: false).
  -s <int> : [Optional] Sample <num_reads> read pairs (Overrides config, Default: 0=all).
  -h       : Display this help message.

    

IGNORE_WHEN_COPYING_START
Use code with caution.
IGNORE_WHEN_COPYING_END

Examples:

    Run initial QC only:

          
    ./bashpipe_fastp_qc.sh \
      -1 path/to/reads_R1.fastq.gz \
      -2 path/to/reads_R2.fastq.gz \
      -o ./qc_results_raw

        

    IGNORE_WHEN_COPYING_START

Use code with caution.Bash
IGNORE_WHEN_COPYING_END

Run QC and Fastp trimming (using 8 threads):

      
./bashpipe_fastp_qc.sh \
  -1 path/to/reads_R1.fastq.gz \
  -2 path/to/reads_R2.fastq.gz \
  -o ./qc_results_trimmed \
  -T \
  -t 8

    

IGNORE_WHEN_COPYING_START
Use code with caution.Bash
IGNORE_WHEN_COPYING_END

Sample 1M reads, then run QC and Fastp trimming:

      
./bashpipe_fastp_qc.sh \
  -1 path/to/reads_R1.fastq.gz \
  -2 path/to/reads_R2.fastq.gz \
  -o ./qc_results_sampled_trimmed \
  -s 1000000 \
  -T \
  -t 4

    

IGNORE_WHEN_COPYING_START
Use code with caution.Bash
IGNORE_WHEN_COPYING_END

Use a configuration file (overriding threads on command line):

      
# Assume pipeline.conf sets ENABLE_FASTP=true and THREADS=8
./bashpipe_fastp_qc.sh \
  -1 path/to/reads_R1.fastq.gz \
  -2 path/to/reads_R2.fastq.gz \
  -o ./qc_results_config_override \
  -c ./pipeline.conf \
  -t 2 # Use 2 threads instead of 8

    

IGNORE_WHEN_COPYING_START

    Use code with caution.Bash
    IGNORE_WHEN_COPYING_END

Configuration File (pipeline.conf)

An optional configuration file can be provided using the -c flag to set default parameters. Command-line arguments always override config file settings.

Example pipeline.conf:

      
# Lines starting with # are comments

# Number of threads for parallel steps
THREADS=8

# Enable Fastp and subsequent FastQC run
ENABLE_FASTP=true

# Number of read pairs to sample (0 = use all)
SAMPLE_READS=0

# Extra parameters for Fastp (must be quoted if containing spaces)
# Example: Trim first 10bp, require length 25, quality 20
FASTP_EXTRA_PARAMS="--trim_front1 10 --trim_front2 10 --length_required 25 -q 20"

# Optional: Override default command paths if not in PATH
# FASTP_CMD=/opt/fastp/fastp
# FASTQC_CMD=/opt/fastqc/fastqc
# MULTIQC_CMD=/usr/local/bin/multiqc
# SEQTK_CMD=~/tools/seqtk/seqtk

    

IGNORE_WHEN_COPYING_START
Use code with caution.Conf
IGNORE_WHEN_COPYING_END
Output Directory Structure

The script creates the following structure within the specified output directory (-o):

      
<output_dir>/
├── 0_Sampled_Reads/      # Contains sampled FASTQ files (if -s used)
├── 1_Raw_FastQC/         # FastQC reports for raw/sampled input reads
├── 2_Trimmed_Reads/      # Trimmed paired FASTQ files from Fastp (if -T used)
├── 3_Trimmed_FastQC/     # FastQC reports for trimmed reads (if -T used)
├── 4_Fastp_Reports/      # HTML and JSON reports from Fastp (if -T used)
├── 5_MultiQC_Report/     # Final aggregated MultiQC HTML report and data
└── logs/                 # Contains detailed pipeline log file(s)

    

IGNORE_WHEN_COPYING_START
Use code with caution.
IGNORE_WHEN_COPYING_END
Workflow Note

For optimal results, it's often recommended to run an initial QC pass (without -T) to review the raw data quality using the MultiQC report. Based on this review, you can then define appropriate FASTP_EXTRA_PARAMS in a pipeline.conf file (e.g., to trim low-quality 5' ends using --trim_front1/--trim_front2) and re-run the pipeline with -T and -c to apply targeted cleaning.
Limitations & Future Work

    This version processes only one pair of input files at a time. Extending it to automatically process multiple pairs from an input directory is a potential enhancement.

    The load_config function uses eval, which can be a security risk if running with untrusted config files. Safer parsing methods could be implemented.

    Error checking could be made more granular (e.g., checking exit codes after every single command).
