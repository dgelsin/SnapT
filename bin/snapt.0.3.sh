#!/usr/bin/env bash
#SBATCH
#SBATCH --job-name=SnapT
#SBATCH --partition=shared
#SBATCH --time=72:0:0
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=100G


VERSION="v0.3"
echo snapt ${@}

##############################################################################################################################################################
# SnapT: Small ncRNA annotation pipeline for transcriptomic data
# This pipeline aligns transcriptomic (or metatranscriptomic) reads to the genome (or metagenome), and finds transcripts that cannot be explained with coding
# regions. These transcripts are further process and curated until the final intergenic and anti-sense small ncRNAs are reported.
#
##############################################################################################################################################################


help_message () {
	echo ""
	echo "Example usage: "
	echo "snapt -1 reads_1.fastq -2 reads_2.fastq -g genome.fa -a genome.gff -o output_dir -d nr.dmnd -t 24 -l 3000"
	echo ""
	echo "SnapT core options:"
	echo "	-1 STR		forward transcriptome (or metatranscriptome) reads"
	echo "	-2 SRT		reverse transcriptome (or metatranscriptome) reads (optional)"
	echo "	-g STR		genome (or metagenome) fasta file"
	echo "	-a STR		genome (or metagenome) annotation gtf/gff file (optional, but recommended)"
	echo "	-l INT		minimum contig length (default=1000) for ncRNA annotation"
	echo "	-o STR          output directory"
	echo "	-t INT		number of threads (default=1)"
	echo "	-d STR		nr protein database DIAMOND .dmnd index (see installation instructions for details)"
	echo "	-rfam STR	run analysis of ncRNAs detected against rfam database (rfam.cm) to annotate known ncRNAs/sRNAs  (see installation instructions for details)"
	echo ""
	echo "Additional options:"
	echo "	-r STR		rna-strandness: R or F for single-end, RF or FR for paired-end (default=FR)"
	echo "	-I INT		min insert size (default=$MIN_INSERT_VALUE)"
	echo "	-X INT		max insert size (default=$MAX_INSERT_VALUE)"
	echo "	-m INT		minimum sRNA size during assembly (default=$MIN_LEN)"
	echo "	-P INT		minimum reads per bp coverage to consider for transcript assembly (default=10)"
	echo ""
	echo "	--version | -v	show current SnapT version"
	echo "";}



comm () { snapt_print_comment.py "$1" "-"; }
error () { snapt_print_comment.py "$1" "*"; exit 1; }
warning () { snapt_print_comment.py "$1" "*"; }
announcement () { snapt_print_comment.py "$1" "#"; }

# loading supplementary scripts
SNAPT_PATH=$(which snapt)
BIN_PATH=${SNAPT_PATH%/*}


########################################################################################################
########################               LOADING IN THE PARAMETERS                ########################
########################################################################################################


# option defaults
STRAND_MAP_VALUE=FR
MIN_INSERT_VALUE=0
MAX_INSERT_VALUE=500
MIN_LEN=50
THREADS=1
LENGTH=1000
MIN_COV=10

OUT=none
READS1=none
READS2=none
GENOME=none
ANNOTATION=none
DATABASE=none
RFAM=none

# load in params
OPTS=`getopt -o hvt:1:2:g:a:o:r:I:X:m:l:d:P: --long help,version -- "$@"`
# make sure the params are entered correctly
if [ $? -ne 0 ]; then help_message; exit 1; fi

# loop through input params
while true; do
        case "$1" in
                -o) OUT=$2; shift 2;;
		-1) READS1=$2; shift 2;;
		-2) READS2=$2; shift 2;;
		-g) GENOME=$2; shift 2;;
		-a) ANNOTATION=$2; shift 2;;
		-t) THREADS=$2; shift 2;;
		-l) LENGTH=$2; shift 2;;
		-d) DATABASE=$2; shift 2;;
		-rfam) RFAM=$2; shift 2;;
		-r) STRAND_MAP_VALUE=$2; shift 2;;
		-I) MIN_INSERT_VALUE=$2; shift 2;;
		-X) MAX_INSERT_VALUE=$2; shift 2;;
		-m) MIN_LEN=$2; shift 2;;
		-P) MIN_COV=$2; shift 2;;
                -h | --help) help_message; exit 0; shift 1;;
		-v | --version) echo SnapT v=${VERSION}; exit 0; shift 1;;
		--skip-refinement) refine=false; shift 1;;
                --) help_message; exit 1; shift; break ;;
                *) break;;
        esac
done


########################################################################################################
########################           MAKING SURE EVERYTHING IS SET UP             ########################
########################################################################################################
# Check if all parameters are entered
if [[ $OUT == none ]] || [[ $READS1 == none ]] || [[ $GENOME == none ]]; then 
	comm "Some non-optional parameters (-1 -g -o) were not entered"
	help_message; exit 1
elif [ ! -s $READS1 ]; then
	error "Read file $READS1 does not exist, or is empty. Exiting."
elif [ ! -s $GENOME ]; then
	error "Genome/metagenome file $GENOME does not exist, or is empty. Exiting."
fi

if [[ $DATABASE == none ]]; then
	warning "You did not specify the NCBI_nr database location with the -d option. SnapT will not be able to perform the homology search!"
fi

if [[ $RFAM == none ]]; then
	warning "You did not specify the rfam database location with the -rfam option. SnapT will not be able to perform the homology search!"
fi

announcement "BEGIN PIPELINE!"
comm "setting up output folder and copying relevant information..."
if [ ! -d $OUT ]; then
        mkdir $OUT
	if [ ! -d $OUT ]; then error "cannot make $OUT"; fi
else
        warning "Warning: $OUT already exists. SnapT will attempt to continue the existing progress, but it is still recommended that you clear this directory to prevent any conflicts"
	#rm -r ${OUT}/*
fi


########################################################################################################
########################         ALIGN RNA READS TO GENOME WITH HISAT2          ########################
########################################################################################################
announcement "ALIGN RNA READS TO GENOME WITH HISAT2"

if [[ -s ${OUT}/hisat2_alignment/hisat2_index.1.ht2 ]]; then
	comm "Looks like the Hisat2 index already exists in the output directory. Skipping..."
else
	comm "Building Hisat2 index from reference genome"
	mkdir ${OUT}/hisat2_alignment
	cp $GENOME ${OUT}/hisat2_alignment/genome.fa
	hisat2-build ${OUT}/hisat2_alignment/genome.fa ${OUT}/hisat2_alignment/hisat2_index \
	 -p $THREADS --quiet
	if [[ $? -ne 0 ]]; then error "Hisat2 index could not be build. Exiting..."; fi
fi



if [[ -s ${OUT}/hisat2_alignment/alignment.bam ]]; then
	comm "Looks like the alignment files aready exist in the output directory. Skipping..."
else
	comm "Aligning $READS1 and $READS2 to $GENOME with hisat2"
	if [[ $READS2 == none ]];then
		hisat2 -p 20 --verbose --no-spliced-alignment\
		 --rna-strandness $STRAND_MAP_VALUE --threads $THREADS --score-min C,-12,\
		 --no-spliced-alignment --quiet\
		 -I $MIN_INSERT_VALUE -X $MAX_INSERT_VALUE\
		 -x ${OUT}/hisat2_alignment/hisat2_index\
		 -U $READS1 -S ${OUT}/hisat2_alignment/alignment.sam
	else
		hisat2 -p 20 --verbose --no-spliced-alignment\
		 --rna-strandness $STRAND_MAP_VALUE --threads $THREADS\
		--no-spliced-alignment --no-mixed --no-discordant --quiet --score-min C,-12,\
		 -I $MIN_INSERT_VALUE -X $MAX_INSERT_VALUE \
		 -x ${OUT}/hisat2_alignment/hisat2_index\
		 -1 $READS1 -2 $READS2 -S ${OUT}/hisat2_alignment/alignment.sam
	fi
	if [[ $? -ne 0 ]]; then error "Hisat2 alignment failed. Exiting..."; fi

	comm "Sorting hisat2 SAM alignment file and converting it to BAM format"
	if [[ -s ${OUT}/hisat2_alignment/alignment.bam.tmp.0000.bam ]]; then rm ${OUT}/hisat2_alignment/alignment.bam*; fi
	samtools sort ${OUT}/hisat2_alignment/alignment.sam -O BAM -o ${OUT}/hisat2_alignment/alignment.bam -@ $THREADS
	if [[ $? -ne 0 ]]; then error "Samtools sorting failed. Exiting..."; fi
	rm ${OUT}/hisat2_alignment/alignment.sam

	comm "Building IGV index from hisat2 i${OUT}/hisat2/alignment.bam and faidx index of $GENOME for IGV inspection"
	samtools faidx ${OUT}/hisat2_alignment/genome.fa
	if [[ $? -ne 0 ]]; then error "Samtools indexing failed. Exiting..."; fi
	samtools index ${OUT}/hisat2_alignment/alignment.bam
	if [[ $? -ne 0 ]]; then error "Samtools indexing failed. Exiting..."; fi
fi


########################################################################################################
########################                  ASSEMBLE TRANSCRIPTS                  ########################
########################################################################################################
announcement "ASSEMBLE TRANSCRIPTS"

if [[ $ANNOTATION == none ]]; then
	comm "Genome annotation not provided. Using Prokka for annotation instead."
	if [[ -s ${OUT}/prokka_annotation/genome.gff ]]; then
		comm "Looks like the Prokka output already exists in the output directory. Skipping..."
		ANNOTATION=${OUT}/prokka_annotation/genome.gff
	else
		comm "Running Prokka on $GENOME. This usually takes a few minutes for single genomes and a few hours for metagenomes."
		prokka --quiet --cpus $THREADS --outdir ${OUT}/prokka_annotation --prefix genome --force $GENOME
		if [[ $? -ne 0 ]]; then error "Prokka annotation failed. Exiting..."; fi
		comm "sorting PROKKA annotation"
		bedtools sort -i ${OUT}/prokka_annotation/genome.gff > ${OUT}/prokka_annotation/genome.sorted.gff
		mv ${OUT}/prokka_annotation/genome.sorted.gff > ${OUT}/prokka_annotation/genome.gff
		ANNOTATION=${OUT}/prokka_annotation/genome.gff
	fi
else
	comm "sorting $ANNOTATION annotation to guide Stringtie"
	bedtools sort -i $ANNOTATION > ${OUT}/sorted_annotation.gff
	if [[ $? -ne 0 ]]; then error "Failed to sort $ANNOTATION. Exiting..."; fi
	ANNOTATION=${OUT}/sorted_annotation.gff
fi


if [[ -s ${OUT}/transcript_assembly/raw_transcripts.gff ]]; then
	comm "Looks like the stringtie assembly already exists in the output directory. Skipping..."
else
	comm "Building reference-based transcripts and transcriptome expression file"
	mkdir ${OUT}/transcript_assembly
	stringtie ${OUT}/hisat2_alignment/alignment.bam \
		-o ${OUT}/transcript_assembly/raw_transcripts.gff \
		-p $THREADS -m $MIN_LEN -G $ANNOTATION -c $MIN_COV
	if [[ $? -ne 0 ]]; then error "Stringtie transcript assembly failed. Exiting..."; fi
fi

########################################################################################################
########################             REMOVE PROTEIN-CODING TRANSCRIPTS          ########################
########################################################################################################
announcement "REMOVE PROTEIN-CODING TRANSCRIPTS"

if [[ -s ${OUT}/transcript_assembly/prodigal_orfs.gff ]]; then
	comm "Looks like the Prodigal ORF predictions are already made. Skipping..."
else
	comm "Predicting open reading frames with Prodigal"
	prodigal -i $GENOME -f gff -o ${OUT}/transcript_assembly/prodigal_orfs.gff -q
	if [[ $? -ne 0 ]]; then error "PRODIGAL failed to annotate genome. Exiting..."; fi
	comm "sorting Prodigal annotation"
	bedtools sort -i ${OUT}/transcript_assembly/prodigal_orfs.gff > ${OUT}/transcript_assembly/prodigal_orfs.sorted.gff
	if [[ $? -ne 0 ]]; then error "Failed to sort prodigal annotation. Exiting..."; fi
	mv ${OUT}/transcript_assembly/prodigal_orfs.sorted.gff ${OUT}/transcript_assembly/prodigal_orfs.gff
fi
ORFS=${OUT}/transcript_assembly/prodigal_orfs.gff

if [[ -s ${OUT}/transcript_assembly/ncRNA.gff ]]; then
	comm "Looks like intersecting the transcripts with the annotation and ORFs was already done. Skipping..."
else
	comm "Intersecting the transcripts with the ORFs found with Prodigal to remove transcripts that are from coding regions"
	snapt_intersect_gff.py $ORFS ${OUT}/transcript_assembly/raw_transcripts.gff > ${OUT}/transcript_assembly/ncRNA.orf.gff
	if [[ ! -s ${OUT}/transcript_assembly/ncRNA.orf.gff ]]; then error "Could not intersect the transcripts with the ORFs. Exiting..."; fi
	comm "Identified $(cat ${OUT}/transcript_assembly/ncRNA.gff | wc -l) putative non-coding transcripts using the Prodigal annotation."

	comm "Intersecting the transcripts with the provided annotation in $ANNOTATION"
	snapt_intersect_gff.py $ANNOTATION ${OUT}/transcript_assembly/raw_transcripts.gff > ${OUT}/transcript_assembly/ncRNA.anno.gff
	if [[ ! -s ${OUT}/transcript_assembly/ncRNA.anno.gff ]]; then error "Could not intersect the transcripts with the provided annotation. Exiting..."; fi
	comm "Identified $(cat ${OUT}/transcript_assembly/ncRNA.anno.gff | wc -l) putative non-coding transcripts using the $ANNOTATION annotation."

	comm "Consolidating intergenic and antisense transcripts predicted from ORFs and $ANNOTATION"
	snapt_consolidate_transcripts.py ${OUT}/transcript_assembly/ncRNA.orf.gff ${OUT}/transcript_assembly/ncRNA.anno.gff > ${OUT}/transcript_assembly/ncRNA.gff
	if [[ ! -s ${OUT}/transcript_assembly/ncRNA.gff ]]; then error "Transcript consolidation failed. Exiting..."; fi
fi

comm "Filtered down to $(cat ${OUT}/transcript_assembly/ncRNA.gff | wc -l) putative non-coding transcripts"
cp ${OUT}/transcript_assembly/ncRNA.gff ${OUT}/nc_rna.gff


########################################################################################################
########################               CURATE NON-CODING TRANSCRIPTS            ########################
########################################################################################################
announcement "CURATE NON_CODING TRANSCRIPTS"

if [[ -s ${OUT}/srna_curation/small_nc_transcripts.gff ]]; then
	comm "Looks like non-coding transcript curation was already done. Skipping..."
else
	mkdir ${OUT}/srna_curation
	mv ${OUT}/nc_rna.gff ${OUT}/srna_curation/raw_nc_transcripts.gff

	comm "re-running Prodigal on isolated transcripts to check for coding regions"
	bedtools getfasta -s -fi $GENOME -bed ${OUT}/srna_curation/raw_nc_transcripts.gff > ${OUT}/srna_curation/raw_nc_transcripts.fa
	if [[ $? -ne 0 ]]; then error "Failed to extract fasta file of transcripts. Exiting..."; fi
	prodigal -i ${OUT}/srna_curation/raw_nc_transcripts.fa -f gff -o ${OUT}/srna_curation/raw_nc_transcripts.prodigal.gff -q
	if [[ $? -ne 0 ]]; then error "Failed to run Prodigal. Exiting..."; fi
	
	comm "pulling out transcripts with ORFs greater than 1/3 of their length"
	snapt_filter_by_prodigal.py ${OUT}/srna_curation/raw_nc_transcripts.prodigal.gff ${OUT}/srna_curation/raw_nc_transcripts.gff\
	 > ${OUT}/srna_curation/raw_nc_transcripts.noorfs.gff
	if [[ $? -ne 0 ]]; then error "Failed to filter out signifficant prodigal hits. Exiting..."; fi

	comm "dynamically thresholding transcripts that are too close to a contig's edge"
	snapt_positional_curation.py $GENOME ${OUT}/srna_curation/raw_nc_transcripts.noorfs.gff ${OUT}/srna_curation/good_nc_transcripts.gff $LENGTH
	if [[ $? -ne 0 ]]; then error "Failed to remove transcripts close to contig edges. Exiting..."; fi

	comm "curating ncRNA predictions by size (minimum 50bp, maximum 500bp)"
	snapt_size_select.py ${OUT}/srna_curation/good_nc_transcripts.gff 50 500 > ${OUT}/srna_curation/small_nc_transcripts.gff 
	if [[ $? -ne 0 ]]; then error "Failed to size select the transcripts. Exiting..."; fi
fi

cp ${OUT}/srna_curation/small_nc_transcripts.gff ${OUT}/small_nc_transcripts.gff
comm "Out of $(cat ${OUT}/srna_curation/good_nc_transcripts.gff | wc -l) ncRNAs, there are $(cat ${OUT}/small_nc_transcripts.gff | wc -l) small ncRNAs, of which $(cat ${OUT}/small_nc_transcripts.gff | grep "intergenic" | wc -l) are intergenic and $(cat ${OUT}/small_nc_transcripts.gff | grep "antisense" | wc -l) are antisense."


########################################################################################################
########################         CROSS REFERING TRANSCRIPTS WITH BLASTX         ########################
########################################################################################################
if [[ $DATABASE == none ]]; then
	announcement "NCBI_nr database not provided. Unable to use homology search to further curate small ncRNAs. You will find the final predictions in ${OUT}/small_nc_transcripts.gff. This is not ideal, but the pipeline completed successfully."
	exit 0
fi

announcement "CROSS REFERING TRANSCRIPTS WITH BLASTX"

if [[ -s ${OUT}/blastx_search/signifficant_hits.list ]]; then
	comm "Looks like DIAMOND Blastx was already run - ${OUT}/blastx_search/signifficant_hits.list exists. Skipping..."
else
	mkdir ${OUT}/blastx_search
	comm "splitting intergenic and antisense transcripts for different alignment options"
	grep "intergenic transcript" ${OUT}/small_nc_transcripts.gff > ${OUT}/blastx_search/intergenic.gff
	grep "antisense transcript" ${OUT}/small_nc_transcripts.gff  > ${OUT}/blastx_search/antisense.gff

	comm "pulling out fasta files of transcripts from $GENOME assembly"
	bedtools getfasta -s -fi ${OUT}/hisat2_alignment/genome.fa -bed ${OUT}/blastx_search/intergenic.gff > ${OUT}/blastx_search/intergenic.fa
	if [[ $? -ne 0 ]]; then error "Failed to pull out fasta file from ${OUT}/blastx_search/intergenic.gff GFF. Exiting..."; fi
	bedtools getfasta -s -fi ${OUT}/hisat2_alignment/genome.fa -bed ${OUT}/blastx_search/antisense.gff > ${OUT}/blastx_search/antisense.fa
	if [[ $? -ne 0 ]]; then error "Failed to pull out fasta file from ${OUT}/blastx_search/antisense.gff GFF. Exiting..."; fi
	
	
	# download and index the nr database:
	# wget ftp://ftp.ncbi.nlm.nih.gov/blast/db/FASTA/nr.gz
	# gunzip nr.gz
	# mv nr nr.faa
	# diamond makedb --in nr.faa -d nr
	comm "running DIAMOND blastx on ${OUT}/blastx_search/intergenic.fa against the $DATABASE database"
	diamond blastx --db $DATABASE --query ${OUT}/blastx_search/intergenic.fa --out ${OUT}/blastx_search/intergenic.blast\
	 --outfmt 6 qseqid sseqid bitscore evalue pident nident qlen slen length mismatch qstart qend sstart send\
	 --threads $THREADS --query-cover 30 --quiet
	if [[ $? -ne 0 ]]; then error "Failed DIAMOND Blastx search against the database. Exiting..."; fi

	comm "running DIAMOND blastx on ${OUT}/blastx_search/antisense.fa against the $DATABASE database"
	diamond blastx --db $DATABASE --query ${OUT}/blastx_search/antisense.fa --out ${OUT}/blastx_search/antisense.blast\
	 --outfmt 6 qseqid sseqid bitscore evalue pident nident qlen slen length mismatch qstart qend sstart send\
	 --threads $THREADS --query-cover 30 --quiet --forwardonly --strand plus
	if [[ $? -ne 0 ]]; then error "Failed DIAMOND Blastx search against the database. Exiting..."; fi


	for BLAST in ${OUT}/blastx_search/*.blast; do
		comm "filtering blastx hits for bit score > 50, evalue < 0.0001, and percent identity > 30"
		# Note that query cover >30% is already done at the alignment step
		cat $BLAST \
		 | awk '{ if ($3>50) print $0 }'\
		 | awk '{ if ($4<0.0001) print $0 }'\
		 | awk '{ if ($5>30) print $0 }'\
		 | cut -f1 | uniq > ${BLAST%.*}.list
	done

	cat ${OUT}/blastx_search/*list | sort | uniq > ${OUT}/blastx_search/signifficant_hits.list
	comm "Out of $(cat ${OUT}/small_nc_transcripts.gff | wc -l) small ncRNA sequences, $(cat ${OUT}/blastx_search/signifficant_hits.list | wc -l) had signifficant hits against the protein database"
fi

comm "pulling out small ncRNA preditions without any blastx hits to the NR database"
snapt_filter_by_blastx.py ${OUT}/blastx_search/signifficant_hits.list ${OUT}/small_nc_transcripts.gff > ${OUT}/blastx_search/blastx-filtered_small_nc_transcripts.gff
if [[ $? -ne 0 ]]; then error "Failed to filter out small ncRNAs without Blastx hits. Exiting..."; fi


########################################################################################################
########################         CROSS REFERING TRANSCRIPTS WITH RFAM         ########################
########################################################################################################
if [[ $RFAM == none ]]; then
	announcement "rfam database not provided. Unable to use homology search to further curate small ncRNAs. You will find the final predictions in ${OUT}/small_nc_transcripts.gff. This is not ideal, but the pipeline completed successfully."
	exit 0
fi

announcement "CROSS REFERING TRANSCRIPTS WITH rfam database"

if [[ -s ${OUT}/rfam_cmscan/rfam_signifficant_hits.list ]]; then
	comm "Looks like rfam cmscan was already run - ${OUT}/rfam_cmscan/rfam_signifficant_hits.list exists. Skipping..."
else
	mkdir ${OUT}/rfam_cmscan
	comm "splitting intergenic and antisense transcripts for different alignment options"
	grep "intergenic transcript" ${OUT}/blastx_search/blastx-filtered_small_nc_transcripts.gff > ${OUT}/rfam_cmscan/intergenic.gff
	grep "antisense transcript" ${OUT}/blastx_search/blastx-filtered_small_nc_transcripts.gff  > ${OUT}/rfam_cmscan/antisense.gff

	comm "pulling out fasta files of transcripts from $GENOME assembly"
	bedtools getfasta -s -fi ${OUT}/hisat2_alignment/genome.fa -bed ${OUT}/rfam_cmscan/intergenic.gff > ${OUT}/rfam_cmscan/intergenic.fa
	if [[ $? -ne 0 ]]; then error "Failed to pull out fasta file from ${OUT}/rfam_cmscan/intergenic.gff GFF. Exiting..."; fi
	bedtools getfasta -s -fi ${OUT}/hisat2_alignment/genome.fa -bed ${OUT}/rfam_cmscan/antisense.gff > ${OUT}/rfam_cmscan/antisense.fa
	if [[ $? -ne 0 ]]; then error "Failed to pull out fasta file from ${OUT}/rfam_cmscan/antisense.gff GFF. Exiting..."; fi
	
	
	# download and index the rfam cm database:
	#wget ftp://ftp.ebi.ac.uk/pub/databases/Rfam/14.1/Rfam.cm.gz
	#gunzip Rfam.cm.gz
	comm "running infernal cmscan on ${OUT}/rfam_cmscan/intergenic.fa against the $RFAM database"
	cmscan --tblout ${OUT}/rfam_cmscan/intergenic_rfam.tblout --notextw --cut_ga --FZ 5 --nohmmonly --cpu 4 $RFAM ${OUT}/rfam_cmscan/intergenic.fa
	if [[ $? -ne 0 ]]; then error "Failed rfam search against the database. Exiting..."; fi

	comm "running DIAMOND blastx on ${OUT}/blastx_search/antisense.fa against the $DATABASE database"
	cmscan --tblout ${OUT}/rfam_cmscan/antisense_rfam.tblout --notextw --cut_ga --FZ 5 --nohmmonly --cpu 4 $RFAM ${OUT}/rfam_cmscan/antisense.fa
	if [[ $? -ne 0 ]]; then error "Failed rfam search against the database. Exiting..."; fi


	for rfam_out in ${OUT}/rfam_cmscan/*.tblout; do
		comm "filtering for non-sRNA rfam ncRNA hits"
		# Note that sRNAs are denoted with the sRNA label in rfam
		cat $rfam_out \
		 | grep -Ev 'sRNA' | tail -n +2 | cut -f3 | uniq > ${rfam_out%.*}.list
	done
	cat ${OUT}/rfam_cmscan/*list | sort | uniq > ${OUT}/rfam_cmscan/signifficant_hits.list
	comm "Out of $(cat ${OUT}/blastx-filtered_small_nc_transcripts.gff | wc -l) small ncRNA sequences, $(cat ${OUT}/rfam_cmscan/signifficant_hits.list | wc -l) had non-sRNA signifficant hits against the rfam database"
fi

comm "pulling out small ncRNA preditions without any non-sRNA infernal hits to the rfam database"
cut -d '"' -f2 ${OUT}/blastx-filtered_small_nc_transcripts.gff | paste - ${OUT}/blastx-filtered_small_nc_transcripts.gff > ${OUT}/blastx-filtered_small_nc_transcripts_with_names.gff
python return_different_lines_file2_from_word_in_file1.py ${OUT}/rfam_cmscan/signifficant_hits.list ${OUT}/blastx-filtered_small_nc_transcripts.gff > ${OUT}/rfam_cmscan/final_small_nc_transcripts_with_names.gff
cut -f2-10 ${OUT}/rfam_cmscan/final_small_nc_transcripts_with_names.gff > ${OUT}/rfam_cmscan/final_small_nc_transcripts.gff
if [[ $? -ne 0 ]]; then error "Failed to filter out small ncRNAs without non-sRNA infernal hits. Exiting..."; fi


########################################################################################################
########################         FINAL PARSING AND CLEAN UP         ########################
########################################################################################################
comm "cleaning up"
rm ${OUT}/blastx-filtered_small_nc_transcripts_with_names.gff
rm ${OUT}/rfam_cmscan/final_small_nc_transcripts_with_names.gff
mv ${OUT}/small_nc_transcripts.* ${OUT}/rfam_cmscan
cp ${OUT}/rfam_cmscan/final_small_nc_transcripts.gff ${OUT}/small_ncRNAs.gff
mv ${OUT}/sorted_annotation.gff ${OUT}/transcript_assembly/sorted_annotation.gff

comm "plotting small ncRNA TMP values for minimum expression cut-off evaluation"
grep "antisense transcript" ${OUT}/small_ncRNAs.gff > ${OUT}/small_antisense_ncRNAs.gff
grep "intergenic transcript" ${OUT}/small_ncRNAs.gff > ${OUT}/small_intergenic_ncRNAs.gff
snapt_tpm_curve.py ${OUT}/small_ncRNAs.gff ${OUT}/small_antisense_ncRNAs.gff ${OUT}/small_intergenic_ncRNAs.gff ${OUT}/expression_curve.png

warning "Please inspect the ${OUT}/expression_curve.png expression curve to confirm that the sRNA expression distribution is roughly exponential. If there is a tail of low-expression transcripts that does not follow a roughly linear trend, it is recommended that you apply a cut-off and remove transcripts below a chosen minimum TPM. Note that the TPMs are available in the GFF file. It there is a long low expression tail, it is also recommended to re-run the pipeline with a higher minimum transcript coverate (-P option)."

comm "pulling out fasta sequences of small ncRNAs"
bedtools getfasta -s -fi ${OUT}/hisat2_alignment/genome.fa -bed ${OUT}/small_antisense_ncRNAs.gff > ${OUT}/small_antisense_ncRNAs.fa
bedtools getfasta -s -fi ${OUT}/hisat2_alignment/genome.fa -bed ${OUT}/small_intergenic_ncRNAs.gff > ${OUT}/small_intergenic_ncRNAs.fa


########################################################################################################
########################     sRNA DISCOVERY PIPELINE SUCCESSFULLY FINISHED!!!   ########################
########################################################################################################
announcement "SMALL NC_RNA DISCOVERY PIPELINE FINISHED SUCCESSFULLY! ANNOTATED $(cat ${OUT}/small_ncRNAs.gff | grep intergenic | wc -l) INTERGENIC AND $(cat ${OUT}/small_ncRNAs.gff | grep antisense | wc -l) ANTISENSE TRANSCRIPTS."


