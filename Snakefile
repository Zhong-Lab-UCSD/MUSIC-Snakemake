import json
import os

configfile:"config.yaml"

FILES = json.load(open(config['SAMPLES_JSON']))
SAMPLES = sorted(FILES.keys())

##-----------------------------------------------##
## Software paths                                ##
##-----------------------------------------------##

python3=config['python3']
cutadapt=config['cutadapt']
bwa=config['bwa']
samtools=config['samtools']
bowtie2=config['bowtie2']
bowtie2-build=config['bowtie2-build']
sambamba=config['sambamba']
Rscript=config['Rscript']

    
rule all:
    input:
        expand("{dir}bowtie2_mapq20_{sample}.stats.txt", dir=config["dir_names"]["mapped_DNA_dir"],sample=SAMPLES),
        expand("{dir}{sample}/bowtie2_mapq20_{sample}.sorted.dedup.bam", dir=config["dir_names"]["dedup_dir"],sample=SAMPLES),
        expand("{dir}{sample}/BWA_uniq_map_{sample}.bam.bai", dir=config["dir_names"]["mapped_RNA_dir"], sample=SAMPLES),
        expand("{dir}{sample}/RNA_BWA_uniq_map_{sample}.sorted.dedup.bam", dir=config["dir_names"]["dedup_dir"], sample=SAMPLES),
        expand("{dir}merge_DNA.sort.bam", dir=config["dir_names"]["merge_dir"], sample=SAMPLES),
        expand("{dir}merge_RNA.sort.bam", dir=config["dir_names"]["merge_dir"], sample=SAMPLES),
        expand("{dir}merge_{type1}.sort.{type2}.csv", dir=config["dir_names"]["stats_dir"], type1=['DNA','RNA'], type2=['cell_reads','cell_clusters','clusters_size']),
        expand("{dir}merge.sort.cluster_rna_dna.csv", dir=config["dir_names"]["stats_dir"])


rule decode:
    input:
        all_read1 = lambda wildcards: FILES[wildcards.sample]['R1'],
        all_read2 = lambda wildcards: FILES[wildcards.sample]['R2']
    output:
        outDNA_fq = config["dir_names"]["decode_dir"] + "{sample}_DNAend_decode.fq",
        outRNA_fq = config["dir_names"]["decode_dir"] + "{sample}_RNAend_decode.fq", 
        decode_log = config["dir_names"]["decode_dir"] + "{sample}_stats.log"
    params:
        s=lambda wc: wc.get("sample")
    shell:
        "{python3} script/1____combo_barcode_resolve.py -R1 {input.all_read1} -R2 {input.all_read2} -lib {params.s} -outRNA {output.outRNA_fq} -outDNA {output.outDNA_fq} -log {output.decode_log}"


rule trimDNA:
    input:
        decode_DNA = rules.decode.output.outDNA_fq
    output:
        trimed_DNA = config["dir_names"]["decode_dir"] + "{sample}_cutadap_trimed_DNAend_decode.fq"
    threads: 5
    shell:
        """
        {cutadapt} -a 'A{{20}}' -a 'G{{20}}' -m 20 -j {threads} -o {output.trimed_DNA} {input.decode_DNA}
        """

rule trimRNA:
    input:
        decode_RNA = rules.decode.output.outRNA_fq
    output:
        trimed_RNA = config["dir_names"]["decode_dir"] + "{sample}_cutadap_trimed_RNAend_decode.fq"
    threads: 5
    shell:
        """
        {cutadapt} -a CGAGGAGCGCTT -a 'A{{20}}N{{20}}' -m 20 -j {threads} -o {output.trimed_RNA} {input.decode_RNA}
        """

rule build_bowtie2_index:
    input:
        fasta_file=config["fasta"]
    params:
        basename=config["dir_names"]["DNA_index_dir"]
    output:
        index_done = config["dir_names"]["DNA_index_dir"]+"_index_done.txt"
    threads: 10
    shell:
        """
        {bowtie2-build} --threads {threads} {input.fasta_file} {params.basename}
        echo "index done" > {output.index_done}
        """
        
        
rule DNAmapping:
    input:
        DNA_fq = rules.trimDNA.output.trimed_DNA,
        index = rules.build_bowtie2_index.output.index_done
    output:
        DNA_human_bam = config["dir_names"]["mapped_DNA_dir"] + "bowtie2_mapq20_{sample}.sorted.bam",
        human_bowtie2_stats = config["dir_names"]["mapped_DNA_dir"] + "bowtie2_mapq20_{sample}.stats.txt",
    params:
        index_prefix = config["dir_names"]["DNA_index_dir"]
    threads: 5 
    shell:
        """
        {bowtie2} -p {threads} -t --phred33 -x {params.index_prefix} -U {input.DNA_fq} 2> {output.human_bowtie2_stats}| {samtools} view -bq 20 -F 4 -F 256 - | {samtools} sort -@ 10 -m 64G -O bam -o {output.DNA_human_bam}
        """


rule dedup_DNA:
    input:
        DNA_human_sorted_bam = rules.DNAmapping.output.DNA_human_bam,
    output:
        DNA_human_dedup_bam = config["dir_names"]["dedup_dir"] + "{sample}/bowtie2_mapq20_{sample}.sorted.dedup.bam"
    shell:
        """
        {python3} script/2____Remove_bam_duplicates.py -inbam {input.DNA_human_sorted_bam} -outbam {output.DNA_human_dedup_bam}
        """


rule Build_bwa_index:
    input:
        fasta_file=config["fasta"],
        gtf_file=config["gtf"]
    params:
        basename_bwa=config["dir_names"]["RNA_index_dir"]+"bwa_index"
    output:
        index_done_bwa=config["dir_names"]["RNA_index_dir"]+"_bwa_index_done.txt"
    threads: 10 
    shell:
        """
        {bwa} index {input.fasta_file} -p {params.basename_bwa}
        echo "bwa index done" > {output.index_done_bwa}
        """
        
        
rule BWA_mapping_RNA:
    input:
        non_rRNA_fq = rules.trimRNA.output.trimed_RNA,
        index_done_bwa = rules.Build_bwa_index.output.index_done_bwa
    params:
        index_prefix = config["dir_names"]["RNA_index_dir"]+"bwa_index"
    output:
        BWA_human_bam = config["dir_names"]["mapped_RNA_dir"] + "{sample}/BWA_uniq_map_{sample}.bam",
        BWA_human_bam_index = config["dir_names"]["mapped_RNA_dir"] + "{sample}/BWA_uniq_map_{sample}.bam.bai",
    threads: 5
    params: "{sample}"
    shell:
        """
        # map to human
		{bwa} mem -t {threads} -SP5M {params.index_prefix} {input.non_rRNA_fq} | {sambamba} view -S -t {threads} -h -f bam -F "mapping_quality >= 1 and not (unmapped or secondary_alignment) and not ([XA] != null or [SA] != null)" /dev/stdin | {sambamba} sort -o {output.BWA_human_bam} /dev/stdin

		{samtools} index {output.BWA_human_bam}
        """

rule dedup_RNA:
    input:
        RNA_human_sorted_bam = rules.BWA_mapping_RNA.output.BWA_human_bam,
    output:
        RNA_human_dedup_bam = config["dir_names"]["dedup_dir"] + "{sample}/RNA_BWA_uniq_map_{sample}.sorted.dedup.bam",
    shell:
        """
        {python3} script/2____Remove_bam_duplicates.py -inbam {input.RNA_human_sorted_bam} -outbam {output.RNA_human_dedup_bam}
        """


rule combine_bam:
    input:
        all_human_dna_bam = expand(config["dir_names"]["dedup_dir"] + "{sample}/bowtie2_mapq20_{sample}.sorted.dedup.bam", sample=SAMPLES),
        all_human_rna_bam = expand(config["dir_names"]["dedup_dir"] + "{sample}/RNA_BWA_uniq_map_{sample}.sorted.dedup.bam", sample=SAMPLES),
    output:
        combine_human_dna = config["dir_names"]["merge_dir"] + "merge_DNA.sort.bam",
        combine_human_rna = config["dir_names"]["merge_dir"] + "merge_RNA.sort.bam",
    threads: 10
    shell:
        """
        {samtools} merge -@ {threads} - {input.all_human_dna_bam} | {samtools} sort -@ 10 -m 64G -O bam -o {output.combine_human_dna}
        {samtools} merge -@ {threads} - {input.all_human_rna_bam} | {samtools} sort -@ 10 -m 64G -O bam -o {output.combine_human_rna}

        """

rule CB_reads_clu_stats:
    input:
        all_human_dna_bam = rules.combine_bam.output.combine_human_dna,
        all_human_rna_bam = rules.combine_bam.output.combine_human_rna
    output:
        expand("{dir}merge_{type1}.sort.{type2}.csv", dir=config["dir_names"]["stats_dir"], type1=['DNA','RNA'], type2=['cell_reads','cell_clusters','clusters_size']),
        cell_stats_done = config['dir_names']['stats_dir']+"cell_stats_done.txt"
    threads: 4
    params:
        dir_=config['dir_names']['stats_dir']
    shell:
        """
        {python3} script/3____cell_reads_cluster_num_stats.py -inbam {input.all_human_dna_bam} -outdir {params.dir_}
        {python3} script/3____cell_reads_cluster_num_stats.py -inbam {input.all_human_rna_bam} -outdir {params.dir_}
        echo "cell_stats_done" > {output.cell_stats_done}
        """

rule eachclusterdnarna:
    input:
        rules.CB_reads_clu_stats.output.cell_stats_done
    output:
        expand("{dir}merge.sort.cluster_rna_dna.csv", dir=config["dir_names"]["stats_dir"])
    params:
        dir_=config["dir_names"]["stats_dir"]
    shell:
        """
        {Rscript} script/4____cluster_DNA_RNA_reads_ct.R {params.dir_}
        """


