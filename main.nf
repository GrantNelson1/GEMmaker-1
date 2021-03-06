#!/usr/bin/env nextflow

/*
* =======
* GEMaker
* =======
 *
 * Authors:
 *  + John Hadish
 *  + Tyler Biggs
 *  + Stephen Ficklin
 *
 * Summary:
 *   A workflow for processing a large amount of fastq_run_id data...
 */


// Display the workflow title and show user parameters.
println """\
=================================
 S R A 2 G E V   P I P E L I N E
=================================

Parameters:
  + Remote fastq list path:      ${params.input.remote_list_path}
  + Local sample glob:           ${params.input.local_samples_path}
  + Genome reference path:       ${params.software_params.hisat2.path}
  + Reference genome prefix:     ${params.software_params.hisat2.prefix}
  + Trimmomatic clip path:       ${params.software_params.trimmomatic.clip_path}
  + Trimmomatic minimum ratio:  ${params.software_params.trimmomatic.MINLEN}
"""

/*
 * Local Sample Input.
 * This checks the folder that the user has given
 */

if (params.input.local_samples_path == 'none'){
  Channel
    .empty()
    .set { LOCAL_SAMPLES }
} else{
  Channel
    .fromFilePairs( params.input.local_samples_path, size: -1 )
    .set { LOCAL_SAMPLES }
}

/*
 * Remote fastq_run_id Input.
 */
if (params.input.remote_list_path == 'none'){
  Channel
     .empty()
     .set { REMOTE_FASTQ_RUNS }
 } else{
  Channel
    .from( file(params.input.remote_list_path).readLines() )
    .set { REMOTE_FASTQ_RUNS }
}

/*
 * The fastq dump process downloads any needed remote fasta files to the
 * current working directory.
 */
process fastq_dump {
  module 'sratoolkit'
  time params.software_params.fastq_dump.time
  tag { fastq_run_id }

  input:
    val fastq_run_id from REMOTE_FASTQ_RUNS

  output:
    set val(fastq_run_id), file("${fastq_run_id}_?.fastq") into DOWNLOADED_FASTQ_RUNS

  """
    fastq-dump --split-files $fastq_run_id
  """
}


/*
 * Combine the remote and local samples into the same channel.
 */
COMBINED_SAMPLES = DOWNLOADED_FASTQ_RUNS.mix( LOCAL_SAMPLES )



/*
 * Performs a SRR/DRR/ERR to sample_id converison:
 *
 * This first checks to see if the format is standard SRR,ERR,DRR
 * This takes the input SRR numbersd and converts them to sample_id.
 * This is done by a python script that is stored in the "scripts" dir
 * The next step combines them
 */
process SRR_to_sample_id {
  module 'python3'
  tag { fastq_run_id }

  input:
    set val(fastq_run_id), file(pass_files) from COMBINED_SAMPLES

  output:
    set stdout, file(pass_files) into GROUPED_BY_SAMPLE_ID mode flatten

  """
  if [[ "$fastq_run_id" == [SDE]RR* ]]; then
    python3 ${PWD}/scripts/retrieve_sample_metadata.py $fastq_run_id

  else
    echo -n "Sample_$fastq_run_id"
  fi
  """
}


/*
 * This groups the channels based on sample_id.
 */
GROUPED_BY_SAMPLE_ID
  .groupTuple()
  .set { GROUPED_SAMPLE_ID }


/**
 * This process merges the fastq files based on their sample_id number.
 */
process SRR_combine{
  publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode
  tag { sample_id }

  input:
    set val(sample_id), file(grouped) from GROUPED_SAMPLE_ID
  output:
    set val(sample_id), file("${sample_id}_?.fastq") into MERGED_SAMPLES

  /** This command tests to see if ls produces a 0 or not by checking
   *its standard out. We do not use a "if [-e *foo]" becuase it gets
   * confused if there are more than one things returned by the wildcard
   */
  """
    if ls *_1.fastq >/dev/null 2>&1; then
      cat *_1.fastq >> "${sample_id}_1.fastq"
    fi

    if ls *_2.fastq >/dev/null 2>&1; then
      cat *_2.fastq >> "${sample_id}_2.fastq"
    fi
  """
}


/*
 * Performs fastqc on fastq files prior to trimmomatic
 */
process fastqc_1 {
  module "fastQC"
  time params.software_params.fastqc_1.time
  stageInMode params.output.staging_mode
  publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode
  tag { sample_id }

  input:
    set val(sample_id), file(pass_files) from MERGED_SAMPLES

  output:
    set val(sample_id), file(pass_files) into MERGED_FASTQC_SAMPLES
    set file("${sample_id}_?_fastqc.html") , file("${sample_id}_?_fastqc.zip") optional true into FASTQC_1_OUTPUT

  """
  fastqc $pass_files
  """
}


/*
 * Performs Trimmomatic on all fastq files.
 *
 * This process requires that the ILLUMINACLIP_PATH environment
 * variable be set in the trimmomatic module. This indicates
 * the path where the clipping files are stored.
 *
 * MINLEN is calculated using based on percentage of the mean
 * read length. The percenage is determined by the user in the
 * "nextflow.config" file
 */
 process trimmomatic {
   module "trimmomatic"
   time params.software_params.trimmomatic.time
   publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode
   tag { sample_id }

   input:
     set val(sample_id), file("${sample_id}_?.fastq") from MERGED_FASTQC_SAMPLES

   output:
     set val(sample_id), file("${sample_id}_??_trim.fastq") into TRIMMED_SAMPLES
     set val(sample_id), file("${sample_id}.trim.out") into TRIMMED_SAMPLE_LOG

   script:
     """
     minlen=`'${PWD}/scripts/Mean_length.sh' '${sample_id}' '${params.software_params.trimmomatic.MINLEN}'`
     if [ -e ${sample_id}_1.fastq ] && [ -e ${sample_id}_2.fastq ]; then
      java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
        PE \
        -threads 1 \
        -phred33 \
        ${sample_id}_1.fastq \
        ${sample_id}_2.fastq \
        ${sample_id}_1p_trim.fastq \
        ${sample_id}_1u_trim.fastq \
        ${sample_id}_2p_trim.fastq \
        ${sample_id}_2u_trim.fastq \
        ILLUMINACLIP:${params.software_params.trimmomatic.clip_path}:2:40:15 \
        LEADING:${params.software_params.trimmomatic.LEADING} \
        TRAILING:${params.software_params.trimmomatic.TRAILING} \
        SLIDINGWINDOW:${params.software_params.trimmomatic.SLIDINGWINDOW} \
        MINLEN:"\$minlen" > ${sample_id}.trim.out 2>&1
     else
      # For ease of the next steps, rename the reverse file to the forward.
      # since these are non-paired it really shouldn't matter.
      if [ -e ${sample_id}_2.fastq ]; then
        mv ${sample_id}_2.fastq ${sample_id}_1.fastq
      fi
      # Even though this is not paired-end, we need to create the 1p.trim.fastq
      # file as an empty file so that the rest of the workflow works
      touch ${sample_id}_1p_trim.fastq
      # Now run trimmomatic
      java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
        SE \
        -threads 1 \
        ${params.software_params.trimmomatic.Quality} \
        ${sample_id}_1.fastq \
        ${sample_id}_1u_trim.fastq \
        ILLUMINACLIP:${params.software_params.trimmomatic.clip_path}:2:40:15 \
        LEADING:${params.software_params.trimmomatic.LEADING} \
        TRAILING:${params.software_params.trimmomatic.TRAILING} \
        SLIDINGWINDOW:${params.software_params.trimmomatic.SLIDINGWINDOW} \
        MINLEN:"\$minlen" > ${sample_id}.trim.out 2>&1
     fi
     """
 }


 /*
  * Performs fastqc on fastq files post trimmomatic
  * Files are stored to an independent folder
  */
process fastqc_2 {
 module "fastQC"
 time params.software_params.fastqc_2.time
 stageInMode params.output.staging_mode
 publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode
 tag { sample_id }

 input:
   set val(sample_id), file(pass_files) from TRIMMED_SAMPLES

 output:
   set val(sample_id), file(pass_files) into TRIMMED_FASTQC_SAMPLES
   set file("${sample_id}_??_trim_fastqc.html"), file("${sample_id}_??_trim_fastqc.zip") optional true into FASTQC_2_OUTPUT

 """
 fastqc $pass_files
 """
}


/*
 * Performs hisat2 alignment of fastq files to a genome reference
 *
 * depends: trimmomatic
 */
process hisat2 {
  module 'hisat2'
  time params.software_params.hisat2.time
  publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode
  tag { sample_id }

  input:
   set val(sample_id), file(input_files) from TRIMMED_FASTQC_SAMPLES

  output:
   set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.sam") into INDEXED_SAMPLES
   set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.sam.log") into INDEXED_SAMPLES_LOG

  script:
   """
     export HISAT2_INDEXES=${params.software_params.hisat2.path}
     if [ -e ${sample_id}_2p_trim.fastq ]; then
       hisat2 \
         -x ${params.software_params.hisat2.prefix} \
         --no-spliced-alignment \
         -q \
         -1 ${sample_id}_1p_trim.fastq \
         -2 ${sample_id}_2p_trim.fastq \
         -U ${sample_id}_1u_trim.fastq,${sample_id}_2u_trim.fastq \
         -S ${sample_id}_vs_${params.software_params.hisat2.prefix}.sam \
         -t \
         -p 1 \
         --un ${sample_id}_un.fastq \
         --dta-cufflinks \
         --new-summary \
         --summary-file ${sample_id}_vs_${params.software_params.hisat2.prefix}.sam.log
     else
       hisat2 \
         -x ${params.software_params.hisat2.prefix} \
         --no-spliced-alignment \
         -q \
         -U ${sample_id}_1u_trim.fastq \
         -S ${sample_id}_vs_${params.software_params.hisat2.prefix}.sam \
         -t \
         -p 1 \
         --un ${sample_id}_un.fastq \
         --dta-cufflinks \
         --new-summary \
         --summary-file ${sample_id}_vs_${params.software_params.hisat2.prefix}.sam.log
     fi
   """
}


/*
 * Sorts the SAM alignment file and coverts it to binary BAM
 *
 * depends: hisat2
 */
process samtools_sort {
  module 'samtools'
  time params.software_params.samtools_sort.time
  publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode
  tag { sample_id }

  input:
    set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.sam") from INDEXED_SAMPLES

  output:
    set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.bam") into SORTED_FOR_INDEX

  script:
    """
    samtools sort -o ${sample_id}_vs_${params.software_params.hisat2.prefix}.bam -O bam ${sample_id}_vs_${params.software_params.hisat2.prefix}.sam
    """
}


/*
 * Indexes the BAM alignment file
 *
 * depends: samtools_index
 */
process samtools_index {
  module 'samtools'
  time params.software_params.samtools_index.time
  publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode, pattern: "*.bam.log"
  tag { sample_id }

  input:
    set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.bam") from SORTED_FOR_INDEX

  output:
    set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.bam") into BAM_INDEXED_FOR_STRINGTIE
    set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.bam.log") into BAM_INDEXED_LOG

  script:
    """
    samtools index ${sample_id}_vs_${params.software_params.hisat2.prefix}.bam
    samtools stats ${sample_id}_vs_${params.software_params.hisat2.prefix}.bam > ${sample_id}_vs_${params.software_params.hisat2.prefix}.bam.log
    """
}


/**
 * Generates expression-level transcript abundance
 *
 * depends: samtools_index
 */
process stringtie {
  module 'stringtie'
  time params.software_params.stringtie.time
  publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode
  tag { sample_id }

  input:
    // We don't really need the .bai file, but we want to ensure
    // this process runs after the samtools_index step so we
    // require it as an input file.
    set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.bam") from BAM_INDEXED_FOR_STRINGTIE

  output:
    set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.ga") into STRINGTIE_GTF

  script:
    """
    stringtie \
    -v \
    -p 1 \
    -e \
    -o ${sample_id}_vs_${params.software_params.hisat2.prefix}.gtf \
    -G ${params.software_params.hisat2.path}/${params.software_params.hisat2.prefix}.gtf \
    -A ${sample_id}_vs_${params.software_params.hisat2.prefix}.ga \
    -l ${sample_id} ${sample_id}_vs_${params.software_params.hisat2.prefix}.bam
    """
}


/*
 * Generates the final FPKM file
 */
process fpkm_or_tpm {
  publishDir params.output.outputdir_sample_id, mode: params.output.staging_mode
  tag { sample_id }

  input:
    set val(sample_id), file("${sample_id}_vs_${params.software_params.hisat2.prefix}.ga") from STRINGTIE_GTF

  output:
    file "${sample_id}_vs_${params.software_params.hisat2.prefix}.fpkm" optional true into FPKMS
    file "${sample_id}_vs_${params.software_params.hisat2.prefix}.tpm" optional true into TPM
  script:
  if( params.software_params.fpkm_or_tpm.fpkm == true && params.software_params.fpkm_or_tpm.tpm == true )
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$8}}' OFS='\t' ${sample_id}_vs_${params.software_params.hisat2.prefix}.ga > ${sample_id}_vs_${params.software_params.hisat2.prefix}.fpkm
    awk -F"\t" '{if (NR!=1) {print \$1, \$9}}' OFS='\t' ${sample_id}_vs_${params.software_params.hisat2.prefix}.ga > ${sample_id}_vs_${params.software_params.hisat2.prefix}.tpm
    """
  else if( params.software_params.fpkm_or_tpm.fpkm == true)
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$8}}' OFS='\t' ${sample_id}_vs_${params.software_params.hisat2.prefix}.ga > ${sample_id}_vs_${params.software_params.hisat2.prefix}.fpkm
    """
  else if( params.software_params.fpkm_or_tpm.tpm == true )
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$9}}' OFS='\t' ${sample_id}_vs_${params.software_params.hisat2.prefix}.ga > ${sample_id}_vs_${params.software_params.hisat2.prefix}.tpm
    """
  else
    error "Please choose at least one output and resume GEMmaker"

}
