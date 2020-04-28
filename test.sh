#!/bin/bash

## Tests for uloz.to downloader
#
# Version: 1.0

function handleError
{
	echo "Error!"
	exit 1
}

trap handleError ERR

downloader='uloz.to-download.sh'

bash "$downloader" 'https://uloz.to/file/CTi4JRWX2hlJ/soubor-zip'
rm -f 'Soubor.zip'

