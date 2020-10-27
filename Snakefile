#!/usr/bin/env python3


#############
# FUNCTIONS #
#############

def get_reads(wildcards):
    input_keys = ['l2r1', 'l2r2', 'l3r1', 'l3r2']
    my_pep = pep.get_sample(wildcards.sample).to_dict()
    return {k: my_pep[k] for k in input_keys}


###########
# GLOBALS #
###########

# samples
pepfile: 'data/config.yaml'
all_samples = pep.sample_table['sample_name']

# references
ref = 'data/ref/GCA_014466185.1_ASM1446618v1_genomic.fna'
gff = 'data/ref/GCA_014466185.1_ASM1446618v1_genomic.gff'
mrna = 'output/000_ref/vvulg.mrna.fa'

# containers
bbmap = 'shub://TomHarrop/seq-utils:bbmap_38.86'
bioconductor = ('shub://TomHarrop/r-containers:bioconductor_3.11'
                '@4fcda9d03ac6b39e038b0d09e67629faa4ca8362')    # has apeglm
# bioconductor = 'shub://TomHarrop/r-containers:bioconductor_3.11'
gffread = 'shub://TomHarrop/assembly-utils:gffread_0.12.3'
salmon = 'docker://combinelab/salmon:1.3.0'
salmontools = 'shub://TomHarrop/align-utils:salmontools_23eac84'
samtools = 'shub://TomHarrop/align-utils:samtools_1.10'


#########
# RULES #
#########

wildcard_constraints:
    sample = '|'.join(all_samples)

rule all:
    input:
        'output/030_deseq/wald/res.annot.csv',

# DE analysis
rule de_wald:
    input:
        dds = 'output/030_deseq/dds.Rds',
    params:
        alpha = 0.1,
        lfc_threshold = 0.585   # log(1.5, 2)
    output:
        ma = 'output/030_deseq/wald/ma.pdf',
        res = 'output/030_deseq/wald/res.csv'
    log:
        'output/logs/de_wald.log'
    threads:
        min(16, workflow.cores)
    container:
        bioconductor
    script:
        'src/de_wald.R'

rule generate_deseq_object:
    input:
        quant_files = expand('output/020_salmon/{sample}/quant.sf',
                             sample=all_samples),
        gff = gff,
        mrna = mrna
    output:
        'output/030_deseq/dds.Rds'
    params:
        index = 'output/005_index',
    log:
        'output/logs/generate_deseq_object.log'
    singularity:
        bioconductor
    script:
        'src/generate_deseq_object.R'

# quantify
rule salmon:
    input:
        'output/005_index/seq.bin',
        'output/005_index/pos.bin',
        r1 = 'output/010_process/{sample}.r1.fastq',
        r2 = 'output/010_process/{sample}.r2.fastq'
    output:
        'output/020_salmon/{sample}/quant.sf'
    params:
        index = 'output/005_index',
        outdir = 'output/020_salmon/{sample}'
    log:
        'output/logs/salmon.{sample}.log'
    threads:
        workflow.cores
    singularity:
        salmon
    shell:
        'salmon quant '
        '--libType ISR '
        '--index {params.index} '
        '--mates1 {input.r1} '
        '--mates2 {input.r2} '
        '--output {params.outdir} '
        '--threads {threads} '
        '--validateMappings '
        '--gcBias '
        '&> {log}'


# process the reads
rule trim:
    input:
        'output/010_process/{sample}.repair.fastq'
    output:
        r1 = 'output/010_process/{sample}.r1.fastq',
        r2 = 'output/010_process/{sample}.r2.fastq'
    params:
        adapters = '/adapters.fa'
    log:
        'output/logs/trim.{sample}.log'
    threads:
        1
    container:
        bbmap
    shell:
        'bbduk.sh '
        'in={input} '
        'int=t '
        'out={output.r1} '
        'out2={output.r2} '
        'ref={params.adapters} '
        'ktrim=r k=23 mink=11 hdist=1 tpe tbo qtrim=r trimq=15 '
        '&> {log}'


rule check_pairing:
    input:
        r1 = 'output/010_process/{sample}.joined.r1.fastq',
        r2 = 'output/010_process/{sample}.joined.r2.fastq',
    output:
        pipe = pipe('output/010_process/{sample}.repair.fastq')
    log:
        'output/logs/{sample}_repair.txt'
    threads:
        1
    container:
        bbmap
    shell:
        'repair.sh '
        'in={input.r1} '
        'in2={input.r2} '
        'out=stdout.fastq '
        '>> {output.pipe} '
        '2> {log}'

rule join_reads:
    input:
        unpack(get_reads)
    output:
        r1 = pipe('output/010_process/{sample}.joined.r1.fastq'),
        r2 = pipe('output/010_process/{sample}.joined.r2.fastq'),
    shell:
        'zcat {input.l2r1} {input.l3r1} >> {output.r1} & '
        'zcat {input.l2r2} {input.l3r2} >> {output.r2} & '
        'wait'

# generic annotation rule
rule annot_res:
    input:
        res = '{path}/{file}.csv',
        annot = 'output/000_ref/annot.csv'
    output:
        res_annot = '{path}/{file}.annot.csv'
    log:
        'output/logs/annot_res.{path}.{file}.log'
    container:
        bioconductor
    script:
        'src/annot_res.R'


# process the reference
rule generate_index:
    input:
        transcriptome = 'output/000_ref/gentrome.fa',
        decoys = 'output/000_ref/decoys.txt'
    output:
        'output/005_index/seq.bin',
        'output/005_index/pos.bin'
    params:
        outdir = 'output/005_index'
    log:
        'output/logs/generate_index.log'
    threads:
        workflow.cores
    singularity:
        salmon
    shell:
        'salmon index '
        '--transcripts {input.transcriptome} '
        '--index {params.outdir} '
        '--threads {threads} '
        '--decoys {input.decoys} '
        '&> {log}'


rule generate_gentrome:
    input:
        fasta = ref,
        transcriptome = mrna
    output:
        'output/000_ref/gentrome.fa',
    container:
        salmon
    shell:
        'cat {input.transcriptome} {input.fasta} > {output}'

rule generate_decoys:
    input:
        f'{ref}.fai'
    output:
        temp('output/000_ref/decoys.txt')
    container:
        salmon
    shell:
        'cut -f1 {input} > {output}'

rule gffread:
    input:
        ref = ref,
        gff = gff,
        fai = f'{ref}.fai'
    output:
        mrna = mrna
    log:
        'output/logs/gffread.log'
    container:
        gffread
    shell:
        'gffread '
        '{input.gff} '
        '-w {output.mrna} '
        '-g {input.ref} '
        '&> {log}'


rule faidx:
    input:
        '{path}/{file}.{ext}'
    output:
        '{path}/{file}.{ext}.fai'
    wildcard_constraints:
        ext = 'fasta|fa|fna'
    singularity:
        samtools
    shell:
        'samtools faidx {input}'

rule parse_annotations:
    input:
        gff = gff
    output:
        annot = 'output/000_ref/annot.csv'
    log:
        'output/logs/parse_annotations.log'
    container:
        bioconductor
    script:
        'src/parse_annotations.R'

