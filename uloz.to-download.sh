#!/bin/bash
#
# Download files form uloz.to in free mode from command line
#
# Version: 2.1.0
# Date: 2020-04-28
# Author: Tomáš Binek <mail@tomasbinek.cz>
# Changelog: 2.1.0 2020-04-28 Uloz.to mechanism changed. Added support for captcha-less downloads. Added multiple tries for downloading the file itself.
#            2.0.1 Added support for reading links from file or stdin
#            2.0.0 Rewrite of previous code
#            
#
# Since there is captcha involved, captcha image is shown to the user.
# Available method for showing the image (in order of descending preference)
#
# X11 + kdialog
# X11 + feh + readline
# X11 + xdg-open + readline
# img2txt + readline
# no image + readline
#
# The last option only prints path to image file and prompts for captcha code.

# Resources used
# https://unix.stackexchange.com/questions/72131/detecting-x-session-in-a-bash-script-bashrc-etc

###

_version=2.1.0

set -e

runMode=
readFromFile=
initialUrl=

# Check environment
which curl &>/dev/null || { echo "Cannot find \`curl\`" >&2; exit 1; }

# Determine mode of operation
if [ "$1" = '--help' ]
then
    runMode=HELP
#
elif [ $# = 0 ]
then
    runMode=LIST
    readFromFile=/dev/stdin
#
elif [ -r "$1" ]
then
    runMode=LIST
    readFromFile="$1"
#
elif egrep -q '^https?://' <<< "$1"
then
    runMode=LINK
    initialUrl="$1"
#
else
    echo "First parameter is not a file, nor a link. Cannot continue." >&2
    exit 1
fi


if [ $runMode = HELP ]
then
    echo $0
    echo 
    echo Uloz.to downloader v$_version
    echo Usage:
    echo $0 url
    exit 0
#
elif [ $runMode = LIST ]
then
    echo "List mode. Reading links from '$1'" >&2
    while read link
    do
        bash $0 "$link" || :
    done < <(tail -n +0 -f "$readFromFile")
    
    exit 0
#
elif [ $runMode = LINK ]
then
    : # continue until the end of script
#
else
    echo "Programming error. runMode $runMode unkown."
    exit 2
fi
    

# Runtime
cookieJar=$(mktemp)
responseDataFile=$(mktemp)
responseHeadersFile=$(mktemp)
captchaFile=$(mktemp --suffix .jpg)
userAgent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) $RANDOM"
    
function cleanup
{
    rm -f "$cookieJar"
    rm -f "$responseDataFile"
    rm -f "$responseHeadersFile"
    rm -f "$captchaFile"
}

function curl_
{
    local curlReturnCode=
    
    #echo "$@"
    curl \
    --user-agent "$userAgent" \
    --cookie-jar "$cookieJar" \
    --cookie "$cookieJar" \
    --dump-header "$responseHeadersFile" \
    "$@" > "$responseDataFile"
    curlReturnCode=$?
    
    # Parse response code
    responseCode=$(sed -nre 's|HTTP/1.1 ([0-9]+) .*|\1|p' < "$responseHeadersFile")
    
    return $curlReturnCode
}

function captchaProperty # name
{
    egrep -o "\"$1\":\"?[^\"]+\"?" < "$responseDataFile" |sed -re 's/"[^"]+":"?([^",}]+).*/\1/' |sed -re 's/\\(.)/\1/g'
}

function hiddenInput # name
{
    cat "$responseDataFile" |egrep -o "<input type=\"hidden\" name=\"$1\" value=\"[^\"]+\"" |egrep -o 'value="[^"]+' |egrep -o '[^"]+$'
}

function propmtUserForCaptcha
{
    local useRead=yes
    local columns_=
    local lines_=
    
    # Try to use X-based image viewer
    if xhost &>/dev/null && which kdialog &>/dev/null
    then
        captchaCode=$(kdialog --title "Uloz.to captcha" --inputbox "<img src='file://$captchaFile'>'")
        useRead=no
    elif xhost &>/dev/null && which feh &>/dev/null
    then
        feh "$captchaFile" &
    elif xhost &>/dev/null && which xdg-open &>/dev/null
    then
        xdg-open "$captchaFile" &

    # Use CLI for image viewing
    elif which img2txt &>/dev/null
    then
        if which tput &>/dev/null
        then
            columns_=$(tput cols)feh
            lines_=$(tput lines)
        else
            columns_=$COLUMNS
            lines_=$LINES
        fi
        img2txt --width $columns_ --height $lines_ "$captchaFile"
    else
        echo "Don't know how to display image file $captchaFile." >&2
        echo "If you can, view it manually." >&2
    fi
    
    [ $useRead = yes ] && read -p "Please enter captcha code: " captchaCode < /dev/tty || :
}

# Step 0 - Preparations
trap cleanup EXIT


# And let's download
echo "Downloading $initialUrl" >&2
downloadOk=no
downloadTriesLeft=25 # Number of tries to download the actual file (after captcha is successful)
while [ $downloadOk != yes ]
do
    # New session
    > "$cookieJar"
    
    # Prepare
    fileId="$(egrep -o 'file/([^/]+)' <<< "$initialUrl" |egrep -o '([^/]+)$')"
    downloadDialogUrl="https://uloz.to/download-dialog/free/default?fileSlug=$fileId&_=$RANDOM"
    
    # Step 1 - Initial request
    curl_ --silent "$initialUrl"
    outputFileName="$(cat "$responseDataFile" |egrep -o '<meta itemprop="name" content="[^"]+">' |egrep -o 'content="[^"]+' |egrep -o '[^"]+$' |tr '/' '_')"
    outputPartFile="$outputFileName.part"    
    
    # Step 3 - Ask for slow download
    curl_ --silent --head "$downloadDialogUrl"
    
    # Did get direct download or captcha?
    downloadUrl="$(sed -nre 's|^Location: (https://uloz\.to/slowDownload/.*)$|\1|p' < "$responseHeadersFile")" || :
    if [ "$downloadUrl" ]
    then
        echo "Download without captcha" >&2
    else
        echo "Captcha-protected download" >&2
        
        # Deal with captcha
        
        # Get captcha data
        curl_ --silent "$downloadDialogUrl"
        captcha_url="https:$(sed -nre 's/\s+<img class="xapca-image" src="([^"]+)".*/\1/p' < "$responseDataFile")" # <img class="xapca-image" src="//xapca3.uloz.to/b33217c498964ac0d56e86bfe01d6b534e058f94/image.jpg"
        captcha_timestamp=$(hiddenInput timestamp)
        captcha_hash=$(hiddenInput hash)
        captcha_salt=$(hiddenInput salt)
        captcha_token="$(hiddenInput _token_)"
        
        # Step 3 - Get captcha image
        curl_ --silent --output "$captchaFile" "$captcha_url"


        # Step 4 - Let the use enter captcha code
        propmtUserForCaptcha


        # Step 5 - Post captcha
        #clear
        curl_ \
            --silent \
            --data _token_=$captcha_token \
            --data timestamp=$captcha_timestamp \
            --data salt=$captcha_salt \
            --data hash=$captcha_hash \
            --data captcha_type=xapca \
            --data captcha_value=$captchaCode \
            --data _do=freeDownloadForm-form-submit \
            "$downloadDialogUrl"
        
        
        # Step 6 - Validate response
        downloadUrl="$(sed -nre 's|^Location: (.*)$|\1|p' < "$responseHeadersFile")" || :
        if [ ! "$downloadUrl" ]
        then
            echo "Did not get file location. Wrong captcha or other problem. Try again." >&2
            continue
        fi
    fi
    
    # Now we can download the file itself
    
    # Step 7 - Go over the redirects manually to allow continuing broken download
    while true
    do        
        if [ $responseCode -eq 200 ]
        then
            break
        else
            fileUrl="$(egrep '^Location: .*' < "$responseHeadersFile" |cut -c `expr length 'Location: ' + 1`- |tr -d '\r')"
        fi
        
        # Get next Location
        curl_ \
            --silent \
            --head \
            "$fileUrl"
    done
    
    
    # Step 8 - Download the file
    while true
    do
        if curl_ \
            --output "$outputPartFile" \
            --continue-at - \
            "$fileUrl"
        then
            echo "Download complete." >&2
            break
        else
            ((downloadTriesLeft--))
            echo "Download failed." >&2
            
            if [ $downloadTriesLeft = 0 ]
            then
                echo "Quitting the attempts to download the file." >&2
                false
            else
                echo "Will try again in 10 seconds." >&2
                sleep 10
            fi
        fi
    done
        
    
    # Step 9 - Rename part file to final name
    mv "$outputPartFile" "$outputFileName"
    
    break
done

# Debug print
#cat "$responseDataFile"
#cat "$cookieJar"
#cat "$responseHeadersFile"
#echo "captcha_timestamp $captcha_timestamp"
#echo "captcha_hash $captcha_hash"
#echo "captcha_salt $captcha_salt"

exit 0
