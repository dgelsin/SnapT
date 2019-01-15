#!/usr/bin/env bash
VERSION="0.1"

##############################################################################################################################################################
# SnapT: Small ncRNA annotation pipeline for transcriptomic data
# This pipeline aligns transcriptomic (or metatranscriptomic) reads to the genome (or metagenome), and finds transcripts that cannot be explained with coding
# regions. These transcripts are further process and curated until the final intergenic and anti-sense small ncRNAs are reported.
#
##############################################################################################################################################################


help_message () {
	echo ""
	echo "Usage: SnapT [options] -1 reads_1.fastq -2 reads_2.fastq -g genome.fa -o output_dir"
	echo ""
	echo "SnapT options:"
	echo "	-1 STR		forward transcriptome (or metatranscriptome) reads"
	echo "	-2 SRT		reverse transcriptome (or metatranscriptome) reads (optional)"
	echo "	-g STR		genome (or metagenome) fasta file"
	echo "	-a STR		genome (or metagenome) annotation gtf file (optional)"
	echo "	-o STR          output directory"
	echo ""
	echo "Aligment options:"
	echo "	-t INT          number of threads (default=1)"
	echo "	-r STR		rna-strandness: R or F for single-end, RF or FR for paired-end (default=FR)"
	echo "	-I INT		min insert size (default=$MIN_INSERT_VALUE)"
	echo "	-X INT		max insert size (default=$MAX_INSERT_VALUE)"
	echo "	-m INT		gap distance to close transcripts (default=$GAP_VALUE)"
	echo ""
	echo "	--version | -v	show current SnapT version"
	echo "";}



comm () { ${SOFT}/print_comment.py "$1" "-"; }
error () { ${SOFT}/print_comment.py "$1" "*"; exit 1; }
warning () { ${SOFT}/print_comment.py "$1" "*"; }
announcement () { ${SOFT}/print_comment.py "$1" "#"; }

# loading supplementary scripts
SNAPT_PATH=$(which snapt.sh)
BIN_PATH=${SNAPT_PATH%/*}
SOFT=${BIN_PATH}/snapt-scripts



########################################################################################################
########################               LOADING IN THE PARAMETERS                ########################
########################################################################################################


# option defaults
STRAND_MAP_VALUE=FR
MIN_INSERT_VALUE=0
MAX_INSERT_VALUE=500
GAP_VALUE=50
THREADS=1

OUT=none
READS1=none
READS2=none
GENOME=none
ANNOTATION=none


# load in params
OPTS=`getopt -o hvt:1:2:g:a:o:r:I:X:m --long help,version -- "$@"`
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
		-r) STRAND_MAP_VALUE=$2; shift 2;;
		-I) MIN_INSERT_VALUE=$2; shift 2;;
		-X) MAX_INSERT_VALUE=$2; shift 2;;
		-m) GAP_VALUE=$2; shift 2;;
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
fi

# Check for correctly configured snapt-scripts folder
if [ ! -s $SOFT/print_comment.py ]; then
	error "The folder $SOFT doesnt exist. Please make sure that the snapt-scripts folder is in the same directory as snapt.sh"
fi

announcement "BEGIN PIPELINE!"
comm "setting up output folder and copying relevant information..."
if [ ! -d $OUT ]; then
        mkdir $OUT
	if [ ! -d $OUT ]; then error "cannot make $OUT"; fi
else
        warning "Warning: $OUT already exists. It is recommended that you clear this directory to prevent any conflicts"
	#rm -r ${OUT}/*
fi


########################################################################################################
########################         ALIGN RNA READS TO GENOME WITH HISAT2          ########################
########################################################################################################
announcement "ALIGN RNA READS TO GENOME WITH HISAT2"

comm "Building Hisat2 index from reference genome"
mkdir ${OUT}/hisat2
cp $GENOME ${OUT}/hisat2/genome.fa
hisat2-build ${OUT}/hisat2/genome.fa ${OUT}/hisat2/hisat2_index \
	 -p $THREADS --quiet
if [[ $? -ne 0 ]]; then error "Hisat2 index could not be build. Exiting..."; fi


comm "Aligning $READS1 and $READS2 to $GENOME with hisat2"
if [[ $READS2 == none ]];then
	hisat2 -p 20 --verbose --no-spliced-alignment\
	 --rna-strandness $STRAND_MAP_VALUE --threads $THREADS \
	 -I $MIN_INSERT_VALUE -X $MAX_INSERT_VALUE\
	 -x ${OUT}/hisat2/hisat2_index\
	 -U $READS1 -S ${OUT}/hisat2/alignment.sam
else
	hisat2 -p 20 --verbose --no-spliced-alignment\
	 --rna-strandness $STRAND_MAP_VALUE --threads $THREADS \
	 -I $MIN_INSERT_VALUE -X $MAX_INSERT_VALUE \
	 -x ${OUT}/hisat2/hisat2_index\
	 -1 $READS1 -2 $READS2 -S ${OUT}/hisat2/alignment.sam
fi
if [[ $? -ne 0 ]]; then error "Hisat2 alignment failed. Exiting..."; fi


comm "Sorting hisat2 SAM alignment file and converting it to BAM format"
samtools sort ${OUT}/hisat2/alignment.sam -O BAM -o ${OUT}/hisat2/alignment.bam -@ $THREADS
if [[ $? -ne 0 ]]; then error "Samtools sorting failed. Exiting..."; fi


comm "Building IGV index from hisat2 i${OUT}/hisat2/alignment.bam"
samtools index ${OUT}/hisat2/alignment.bam
if [[ $? -ne 0 ]]; then error "Samtools indexing failed. Exiting..."; fi


########################################################################################################
########################              ASSEMBLE DE-NOVO TRANSCRIPTS              ########################
########################################################################################################
announcement "ASSEMBLE DE-NOVO TRANSCRIPTS"

comm "Building de-novo transcripts and transcriptome expression file"
stringtie ${OUT}/hisat2/alignment.bam \
	-o ${OUT}/raw_transcripts.gff \
	-p $THREADS -m $GAP_VALUE
if [[ $? -ne 0 ]]; then error "Stringtie transcript assembly failed. Exiting..."; fi


########################################################################################################
########################             REMOVE PROTEIN-CODING TRANSCRIPTS          ########################
########################################################################################################
announcement "REMOVE PROTEIN-CODING TRANSCRIPTS"

comm "Predicting open reading frames with Prodigal"
prodigal -i $GENOME -f gff -o ${OUT}/prodigal_orfs.gff -q
if [[ $? -ne 0 ]]; then error "PRODIGAL failed to annotate genome. Exiting..."; fi



ORFS=${OUT}/prodigal_orfs.gff

comm "Intersecting the transcripts with the ORFs found with Prodigal to remove transcripts that are from coding regions"
${SOFT}/intersect_gff.py $ORFS ${OUT}/raw_transcripts.gff > ${OUT}/ncRNA.gff
if [[ $? -ne 0 ]]; then error "Could not intersect the transcripts with the ORFs. Exiting..."; fi

if [[ $ANNOTATION != none ]]; then
	comm "Intersecting the transcripts with the provided annotation in $ANNOTATION"
	${SOFT}/intersect_gff.py $ANNOTATION ${OUT}/raw_transcripts.gff > ${OUT}/ncRNA.anno.gff
	if [[ $? -ne 0 ]]; then error "Could not intersect the transcripts with the provided annotation. Exiting..."; fi

	comm "Consolidating intergenic and antisense transcripts predicted from ORFs and $ANNOTATION"
	mv ${OUT}/ncRNA.gff ${OUT}/ncRNA.orf.gff
	${SOFT}/consolidate_transcripts.py ${OUT}/ncRNA.orf.gff ${OUT}/ncRNA.anno.gff > ${OUT}/ncRNA.gff
	if [[ $? -ne 0 ]]; then error "Transcript consolidation failed. Exiting..."; fi
fi

mkdir ${OUT}/transcript_assembly
mv ${OUT}/*gff ${OUT}/transcript_assembly
cp ${OUT}/transcript_assembly/ncRNA.gff ${OUT}/nc_rna.gff


########################################################################################################
########################               CURATE NON-CODING TRANSCRIPTS            ########################
########################################################################################################
announcement "CURATE NON_CODING TRANSCRIPTS"

mkdir ${OUT}/srna_curation
mv ${OUT}/nc_rna.gff ${OUT}/srna_curation/raw_nc_transcripts.gff

comm "dynamically thresholding transcripts that are too close to a contig's edge"
${SOFT}/positional_thresholding.py $GENOME ${OUT}/srna_curation/raw_nc_transcripts.gff > ${OUT}/srna_curation/good_nc_transcripts.gff
if [[ $? -ne 0 ]]; then error "Failed to remove transcripts close to contig edges. Exiting..."; fi
cp ${OUT}/srna_curation/good_nc_transcripts.gff ${OUT}/nc_transcripts.gff


########################################################################################################
########################     sRNA DISCOVERY PIPELINE SUCCESSFULLY FINISHED!!!   ########################
########################################################################################################
announcement "sRNA DISCOVERY PIPELINE FINISHED SUCCESSFULLY!"

