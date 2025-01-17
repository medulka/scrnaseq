////////////////////////////////////////////////////
/* --         SALMON ALEVIN WORKFLOW           -- */
////////////////////////////////////////////////////

params.summary_params = [:]

////////////////////////////////////////////////////
/* --     Collect configuration parameters     -- */
////////////////////////////////////////////////////

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(', ')}"
}

//Check if GTF is supplied properly
if( params.gtf ){
    Channel
        .fromPath(params.gtf)
        .ifEmpty { exit 1, "GTF annotation file not found: ${params.gtf}" }
        .set { gtf }
}

// Check if TXP2Gene is provided for Alevin
if (!params.gtf && !params.txp2gene){
    exit 1, "Must provide either a GTF file ('--gtf') or transcript to gene mapping ('--txp2gene') to align with Alevin"
}

//Setup FastA channels
if( params.genome_fasta ){
    Channel
        .fromPath(params.genome_fasta)
        .ifEmpty { exit 1, "Fasta file not found: ${params.genome_fasta}" }
        .set { genome_fasta }
}

//Setup Transcript FastA channels
if( params.transcript_fasta ){
    Channel
        .fromPath(params.transcript_fasta)
        .ifEmpty { exit 1, "Fasta file not found: ${params.transcript_fasta}" }
        .set { transcriptome_fasta }
}

// Check if files for index building are given if no index is specified
if (!params.salmon_index && (!params.genome_fasta)) {
    exit 1, "Must provide a genome fasta file ('--genome_fasta') or a transcript fasta ('--transcript_fasta') if no index is given!"
}

//Setup channel for salmon index if specified
if (params.salmon_index) {
    Channel
        .fromPath(params.salmon_index)
        .ifEmpty { exit 1, "Salmon index not found: ${params.salmon_index}" }
        .set { salmon_index_alevin }
}

// Create a channel for input read files
if (params.input)      { ch_input      = file(params.input)      } else { exit 1, 'Input samplesheet file not specified!' }

// Check if txp2gene file has been provided
if (params.txp2gene){
    Channel
        .fromPath(params.txp2gene)
        .set{ ch_txp2gene }
}

// Stage config files
ch_multiqc_config = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$projectDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$projectDir/docs/images/", checkIfExists: true)

// Get the protocol parameter
(protocol, chemistry) = Workflow.formatProtocol(params.protocol, "alevin")

//Whitelist files for STARsolo and Kallisto
whitelist_folder = "$baseDir/assets/whitelist/"

//Automatically set up proper filepaths to the barcode whitelist files bundled with the pipeline
if (params.protocol.contains("10X") && !params.barcode_whitelist){
    barcode_filename = "$whitelist_folder/10x_${chemistry}_barcode_whitelist.txt.gz"
    Channel.fromPath(barcode_filename)
        .ifEmpty{ exit 1, "Cannot find ${protocol} barcode whitelist: $barcode_filename" }
        .set{ barcode_whitelist_gzipped }
} else if (params.barcode_whitelist){
    Channel.fromPath(params.barcode_whitelist)
        .ifEmpty{ exit 1, "Cannot find ${protocol} barcode whitelist: $barcode_filename" }
        .set{ ch_barcode_whitelist }
}


////////////////////////////////////////////////////
/* --    IMPORT LOCAL MODULES/SUBWORKFLOWS     -- */
////////////////////////////////////////////////////
include { INPUT_CHECK        }                from '../subworkflows/local/input_check'
include { GFFREAD_TRANSCRIPTOME }             from '../modules/local/gffread_transcriptome'
include { SALMON_ALEVIN }                     from '../modules/local/salmon_alevin'
include { ALEVINQC }                          from '../modules/local/alevinqc'
include { CUSTOM_DUMPSOFTWAREVERSIONS }             from '../modules/nf-core/modules/custom/dumpsoftwareversions/main'
include { MULTIQC }                           from '../modules/local/multiqc_alevin'

////////////////////////////////////////////////////
/* --    IMPORT NF-CORE MODULES/SUBWORKFLOWS   -- */
////////////////////////////////////////////////////
include { GUNZIP }                      from '../modules/nf-core/modules/gunzip/main'
include { GFFREAD as GFFREAD_TXP2GENE } from '../modules/nf-core/modules/gffread/main'
include { SALMON_INDEX }                from '../modules/nf-core/modules/salmon/index/main'

////////////////////////////////////////////////////
/* --           RUN MAIN WORKFLOW              -- */
////////////////////////////////////////////////////
def multiqc_report    = []

workflow SCRNASEQ_ALEVIN {
    ch_software_versions = Channel.empty()

    /*
    * Check input files and stage input data
    */
    INPUT_CHECK( ch_input )
    .reads
    .map {
        meta, reads -> meta.id = meta.id.split('_')[0..-2].join('_')
        [ meta, reads ]
    }
    .groupTuple(by: [0])
    .map { it -> [ it[0], it[1].flatten() ] }
    .set { ch_fastq }

    // unzip barcodes
    if (params.protocol.contains("10X") && !params.barcode_whitelist) {
        GUNZIP( barcode_whitelist_gzipped.map { it -> [[:], it] } )
        ch_barcode_whitelist = GUNZIP.out.gunzip.map{ meta, res -> res}
    }

    // Preprocessing - Extract transcriptome fasta from genome fasta
    if (!params.transcript_fasta && params.genome_fasta && params.gtf) {
        GFFREAD_TRANSCRIPTOME( genome_fasta, gtf )
        transcriptome_fasta = GFFREAD_TRANSCRIPTOME.out.transcriptome_extracted
        ch_software_versions = ch_software_versions.mix(GFFREAD_TRANSCRIPTOME.out.versions.first().ifEmpty(null))
    }

    /*
    * Build salmon index
    */
    if (!params.salmon_index) {
        SALMON_INDEX( genome_fasta, transcriptome_fasta )
        salmon_index_alevin = SALMON_INDEX.out.index
    }

    /*
    * Build txp2gene map
    */
    if (!params.txp2gene){
        GFFREAD_TXP2GENE( gtf )
        ch_txp2gene = GFFREAD_TXP2GENE.out.gtf
        // Only collect version if not already done for gffread
        if (!GFFREAD_TRANSCRIPTOME.out.versions) {
            ch_software_versions = ch_software_versions.mix(GFFREAD_TXP2GENE.out.versions.first().ifEmpty(null))
        }
    }

    /*
    * Perform quantification with salmon alevin
    */
    SALMON_ALEVIN (
        ch_fastq,
        salmon_index_alevin.collect(),
        ch_txp2gene.collect(),
        protocol,
        ch_barcode_whitelist.collect()
    )
    ch_software_versions = ch_software_versions.mix(SALMON_ALEVIN.out.versions.first().ifEmpty(null))
    ch_salmon_multiqc = SALMON_ALEVIN.out.alevin_results

    /*
    * Run alevinQC
    */
    ALEVINQC( SALMON_ALEVIN.out.alevin_results )
    ch_software_versions = ch_software_versions.mix(ALEVINQC.out.versions.first().ifEmpty(null))

    // collect software versions
    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_software_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    /*
    * MultiQC
    */
    if (!params.skip_multiqc) {
        workflow_summary    = Workflow.paramsSummaryMultiqc(workflow, params.summary_params)
        ch_workflow_summary = Channel.value(workflow_summary)

        MULTIQC (
            ch_multiqc_config,
            ch_multiqc_custom_config.collect().ifEmpty([]),
            CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect(),
            ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'),
            ch_salmon_multiqc.collect{it[1]}.ifEmpty([]),
        )
        multiqc_report = MULTIQC.out.report.toList()
    }

}

////////////////////////////////////////////////////
/* --              COMPLETION EMAIL            -- */
////////////////////////////////////////////////////

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
}

////////////////////////////////////////////////////
/* --                  THE END                 -- */
////////////////////////////////////////////////////
