#!/bin/bash

# set details
DOIMAGE="72401866"
DOSIZE="m3-4vcpu-32gb"
DOREGION="AMS3"
DONAME="bitclout-$RANDOM"

# introduction
echo "Welcome to CloutPrinter by @tijn!"
echo "---------------------------------"
echo
echo "Running this script will:"
echo
echo "- launch a BitClout node on the DigitalOcean clout"
echo "- wait for it to sync the blockchain"
echo "- print out all posts to the screen"
echo
echo "To be able to do this, it needs to make sure you have the following tools installed:"
echo "- Package manager: homebrew"
echo "- cli tools: jq & wget"
echo "- Digital Ocean CLI: doctl"
echo

# check were on macos
if [[ ! "$OSTYPE" == "darwin"* ]]; then
    echo "This script only works on MacOs"
    exit
fi

# install homebrew
echo
echo "Need to make sure you have a few apps installed."
echo "Press enter to start"
read

echo "Installing Homebrew"
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo

echo "Installing doctl, jq and wget tool for Digital Ocean"
brew install doctl
brew install doctl jq wget 

# configure account
echo
echo "Please authenticate the DO cli tool to your account"

if ! DOAUTH=(`doctl auth list | sed -e "s/(current)//"`); then
    echo "You are not logged into your DO account."
    echo "If you dont have an account create one here:"
    echo "https://m.do.co/c/0c7459043159"
    echo
    echo "Then create a API token here:"
    echo "https://cloud.digitalocean.com/account/api/tokens"
    echo "* Make sure you enable read & write access"
    echo
    doctl auth init --context bitclout
    DOAUTH=(`doctl auth list | sed -e "s/(current)//"`)
fi
select ACCOUNT in "${DOAUTH[@]}"; do
    doctl auth switch --context $ACCOUNT
    break
done
echo
echo "DO account selected: $ACCOUNT"
doctl account get --format "Email"
echo
echo -n "Do you want to proceed? Enter to continue"
read

# create keypair
echo
echo "Is the SSH key set already?"
if [ ! -f ./keys/bitclout ]; then
    echo "Creating new key file"
    ssh-keygen -f ./keys/bitclout -t rsa -b 4096 -C "dummy@email.com" -q -N ""
    doctl compute ssh-key import bitclout --public-key-file ./keys/bitclout.pub
    echo "[ok] ssh key created, and uploaded to digital ocean"
else
    echo "[ok] SSH Key exists already"
fi

FINGERPRINT=$(ssh-keygen -E md5 -lf ./keys/bitclout | cut -d' ' -f2 | cut -c 5-)

# make sure it exists on DO
doctl compute ssh-key get $FINGERPRINT &> /dev/null
if [ $? -ne 0 ]; then
    echo "[ERROR] Your ssh key file exists locally, but has not been created in Digital Ocean"
    echo "- please remove the files in: ./keys/, and restart the script"
    exit
fi

# create droplet
echo
echo "Creating droplet ... please wait "
DROPLETIP=$(doctl compute droplet create $DONAME \
    --enable-backups \
    --enable-ipv6 \
    --enable-monitoring \
    --image $DOIMAGE \
    --region $DOREGION \
    --size $DOSIZE \
    --ssh-keys $FINGERPRINT \
    --user-data-file ./userdata.sh \
    --wait \
    --no-header \
    --format "PublicIPv4")
echo "[OK] Droplet created: $DROPLETIP"

#wait for web to come up
echo 
echo -n "Bitclout is now being installed..."
until $(curl --max-time 2 --output /dev/null --silent --head --fail "http://$DROPLETIP"); do
    echo -n "."
    sleep 5
done
echo
echo "[ok] droplet created"

#is server up
DROPLETIP="167.71.15.160"

BLOCK=6044 #this was block with first post, so lets start there
MAXHEIGHT=$(curl -s https://api.bitclout.com/api/v1 | jq '.Header.Height')
echo
echo "There are $MAXHEIGHT blocks on Bitclout."
echo "First we need to download the headers for all the blocks"
echo

until [ "$BLOCK" -eq "$MAXHEIGHT" ]; do
    NODESTATUS=$(curl -s "http://$DROPLETIP/api/v0/admin/node-control" -X 'POST' -H 'Content-Type: application/json' --data-binary '{"AdminPublicKey":"","Address":"","OperationType":"get_info"}' | jq '.BitCloutStatus')
    STATE=$(jq -r '.State' <<< $NODESTATUS)
    HEADERS=$(jq -r '.HeadersRemaining' <<< $NODESTATUS)
    BLOCKS=$(jq -r '.BlocksRemaining' <<< $NODESTATUS)
    TSINDEX=$(jq -r '.LatestTxIndexHeight' <<< $NODESTATUS)

    if [ "$STATE" = "SYNCING_HEADERS" ]; then
        echo -ne "$STATE: $HEADERS remaining...                            \r"
        sleep 2
        continue
    elif [ "$STATE" = "SYNCING_BITCOIN" ]; then
        echo -ne "Just a quick sync with Bitcoin! You wont even see this   \r"
        sleep 2
        continue
    elif [ "$STATE" = "SYNCING_BLOCKS" ]; then
        if [ "$BLOCKS" -gt 28734 ]; then
            LEFT="$(($BLOCKS-28734))"
            echo -ne "$STATE: Load Empty Blocks First, $LEFT remaining         \r"
            continue
        else
            # OK now show some posts while we sync remainder
            POSTS=$(curl -s "http://$DROPLETIP/api/v0/get-posts-stateless" -X POST -H 'Content-Type: application/json' --data-raw '{ "ReaderPublicKeyBase58Check":"", "PostHashHex":"", "NumToFetch":100, "GetPostsForFollowFeed": false, "GetPostsForGlobalWhitelist": false, "GetPostsByClout": false, "OrderBy": "oldest", "StartTstampSecs": 0, "PostContent": "", "FetchSubcomments": false, "MediaRequired": false, "PostsByCloutMinutesLookback": 0, "AddGlobalFeedBool": false }' | jq -c '.PostsFound[]')
            
            while read -r POST
            do
                USER=$(jq -r '.ProfileEntryResponse.Username' <<< $POST)
                DATE=$(jq -r '.TimestampNanos / 1000000000 | strftime("on %d %m %Y at %H:%M:%S (UTC)")' <<< $POST)
                BODY=$(jq -r '.Body' <<< $POST)

                echo "🗣  $USER posted on $DATE:"
                printf "%s\n" "$BODY"
                echo
                sleep 2
            done <<< "$POSTS"
        fi
    fi

    echo
    echo "[SYNC STATUS] $STATE at Height $MAXHEIGHT, with index at $TSINDEX"
    echo

    # if there are indexed blocks, get the posts
    until [ $BLOCK -ge $MAXHEIGHT ]; do
        if [ $TSINDEX -gt $BLOCK ]; then
            BLOCKDATA=$(curl -s "http://$DROPLETIP/api/v1/block" -X 'POST' -H 'Content-Type: application/json' --data-binary "{\"Height\":${BLOCK}, \"FullBlock\":true}")
            POSTS=$(jq -r '.Transactions[] | select(.TransactionType=="SUBMIT_POST") | .TransactionMetadata.SubmitPostTxindexMetadata.PostHashBeingModifiedHex' <<< $BLOCKDATA )
            if [ ! -z "$POSTS" ]; then
                while read -r POSTID
                do
                    POST=$(curl -s "http://$DROPLETIP/api/v0/get-single-post" -X POST -H 'Content-Type: application/json' --data-raw "{ \"ReaderPublicKeyBase58Check\":\"\", \"PostHashHex\":\"$POSTID\",  \"FetchParents\": false, \"CommentOffset\": 0, \"CommentLimit\": 0, \"AddGlobalFeedBool\": false }" | jq -c '.PostFound')
                    if [ ! -z "$POST" ] && [ ! "$POST" = "null" ]; then
                        USER=$(jq -r '.ProfileEntryResponse.Username' <<< $POST)
                        DATE=$(jq -r '.TimestampNanos / 1000000000 | strftime("on %d %m %Y at %H:%M:%S (UTC)")' <<< $POST)
                        BODY=$(jq -r '.Body' <<< $POST)

                        echo "🗣  $USER posted on $DATE:"
                        printf "%s\n" "$BODY"
                        echo
                    fi
                done <<< "$POSTS"
            fi
            BLOCK=$((BLOCK+1))
        else
            echo -ne "WAITING FOR INDEXED BLOCKS: $BLOCK vs $TSINDEX       /r"
        fi
    done
done

echo 
echo "DONE!!"