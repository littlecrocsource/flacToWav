#! /usr/bin/bash

# =============================================================================
## Color formats
#
# Red 31
# Green 32
# Yellow 33
# Blue 34
# Magenta 35
# Cyan 36
# Bright Cyan 96
# Bright Magenta 95
# Bright  Blue 94
# Bright Yellow 93
# Bright Green 92
# Bright Red 91
#
# =============================================================================
BLINK_TXT='\e[1;32m'
PLAIN_TXT='\e[0m'
OK_TXT='\e[1;92m'
EXIT_TXT='\e[1;96m'
ABORT_TXT='\e[1;91m'
MAG_TXT='\e[1;95m'
WARN_TXT='\e[1;93m'

convert_file()
{
    FILE=$*
    if [ -f "$FILE" ]; then
        echo "Converting $FILE:..."
        printf "\n"
        newFileName=${FILE%%'.flac'*}
        OUTNAME="wav16/$newFileName.wav"

        mkdir -p wav16

        ffmpeg -hide_banner -i "$FILE" -ar 44100 -map_metadata 0 "$OUTNAME"

    else

        printf '%b' "${ABORT_TXT}$FILE${PLAIN_TXT} can't be found. Please re-try!\n"
    fi
}

printf '%b' "
 ____ _             ${BLINK_TXT}______${PLAIN_TXT}
/  __) |           ${BLINK_TXT}(_____ \ ${PLAIN_TXT}
| |__| | ____  ____  ${BLINK_TXT}____) ) _ _  ____ _   _${PLAIN_TXT}
|  __) |/ _  |/ ___)${BLINK_TXT}/_____/ | | |/ _  | | | |${PLAIN_TXT}
| |  | ( ( | ( (___ ${BLINK_TXT}______| | | ( ( | |\ V /${PLAIN_TXT}
|_|  |_|\_||_|\____|${BLINK_TXT}_______)____|\_||_| \_/${PLAIN_TXT}"

printf '%b' "\n\n${MAG_TXT}FFMPEG audio formatter\n${PLAIN_TXT}"
echo "Converts .flac to .wav"
printf '%b' "PCM 16bit @44.1kHz\n\n"

echo "File selected to convert: $1"

while
    printf '%b' "Ready to convert file. ${WARN_TXT}Continue? [y/N]: ${PLAIN_TXT}"
    read -r CONFIRM
    [[ $CONFIRM != [yN] ]]
do true; done

printf "\n"

if [[ $CONFIRM == "y" ]]; then
    case $1 in
        --all)
            for file in *; do
                if [[ $file == *".flac"* ]]; then
                    convert_file "$file"
                fi
            done
            ;;
        *)
            convert_file "$1"
            ;;
    esac
    printf '%b' "${OK_TXT}\ndone!!!${PLAIN_TXT}\n"

else
    printf '%b' "${EXIT_TXT}\n[ program aborted ]${PLAIN_TXT}\n"
fi
