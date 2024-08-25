#!/bin/bash
logfile=''
cachedir=''
zone_id=''
api_token=''
domains=''
#Give full path for a file that contains your domains
#Make the logfile yourself and add the full path here

#Defining logging
log() {
        body="$1"
        if [[ -f "$logfile" ]]; then
                echo "$(date +'%H:%M %d/%m/%y') ${body}" >> "$logfile"
        fi
}

#Fetch Public IP
getPubIP() {
        publicIP=$(curl --silent ipinfo.io | jq -r .ip 2>> $logfile)
        #publicIP="Some random String"
        if [[ $(echo "$publicIP" | grep [A-z]) ]]; then
                log "ERROR Can't get public IP"
        else
                log "INFO Got $publicIP as public IP"
        fi
}

#Fetch current A record
getDNS() {
        local httpRq curlTmp errTmp curlErr hostMsg
        unset identifier

        curlTmp=$(mktemp "$cachedir/getDNS.XXXX")
        errTmp=$(mktemp "$cachedir/getDNSerror.XXXX")

        httpRq=$(curl --silent --show-error -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=${1}" \
                -H "X-Auth-Key: $api_token" \
                -H "Content-Type: application/json" \
                --output "$curlTmp" \
                --write-out "%{http_code}" \
                --stderr "$errTmp")

        curlErr=$(cat "$errTmp")
        hostMsg=$(head -1 $curlTmp)

        if (( httpRq == 200 )); then
                identifier=$(jq -j .result[].id "$curlTmp")
                rm $curlTmp $errTmp
        else
                log "ERROR ${1}: $curlErr $httpRq Response: $hostMsg getDNS"
                rm $curlTmp $errTmp
                :
        fi
}
updateDNS() {
        local httpRq curlTmp errTmp curlErr hostMsg run
        unset updatedIP

        curlTmp=$(mktemp "$cachedir/updateDNS.XXX")
        errTmp=$(mktemp "$cachedir/updateDNSerror.XXX")

        httpRq=$(curl --silent --show-error -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$identifier" \
                -H "X-Auth-Key: $api_token" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"A\",\"name\":\"${1}\",\"content\":\"$publicIP\",\"proxied\":false}" \
                --output "$curlTmp" \
                --write-out "%{http_code}" \
                --stderr "$errTmp")

        curlErr=$(cat $errTmp)
        hostMsg=$(head -1 "$curlTmp")

        if (( httpRq == 200 )); then
                updatedIP=$(jq -j .result.content "$curlTmp")
                rm "$curlTmp" "$errTmp"
        else
                log "ERROR ${1}: $curlErr $httpRq Response: $hostMsg updateDNS"
                rm $curlTmp $errTmp
                :
        fi
}

#Update the cache
updateCache() {
        cat <<- EOF > "$cachedir/${1}"
        cDate='$(date)'
        cID=$identifier
        cIP=$updatedIP
        cStamp=$(date +%s)

        EOF

        chmod 600 "$cachedir/${1}"
}

#Main
getDNS
for i in $(cat $domains); do
        echo $i
        if [[ -f "$cachedir/$i" ]]; then
                source "$cachedir/$i"
                  if [[ "$cachedir" != "$publicIP" ]]; then
                        getDNS "$i"
                        echo $?
                        updateDNS "$i"
                        updateCache "$i"
                        log "INFO A record for $i updated from $cIP to $updatedIP"
                elif (( cStamp < $(date -d 'now - 1 months' +%s) )); then
                        getDNS "$i"
                        updateDNS "$i"
                        updateCache "$i"
                        log "INFO DNS force update for $i from $cIP to $updatedIP"
                fi
        else
                mkdir -p "$cachedir"
                chown $(whoami):$(whoami) "$cachedir"
                chmod 700 "$cachedir"

                getDNS "$i"
                updateDNS "$i"
                updateCache "$i"
                log "INFO A record for $i updated for the first time to $updatedIP"
        fi
done
