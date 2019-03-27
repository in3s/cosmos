#!/bin/bash

for i in curl cut date fgrep gaiacli jq tee ; do [[ $(command -v $i) ]] || { echo "$i is not in PATH; PATH == $PATH; cannot proceed" ; exit -1 ; } ; done # https://unix.stackexchange.com/a/379425

DELEGATEE=${GAIACLI_DELEGATEE:-"cosmosvaloper1rcp29q3hpd246n6qak7jluqep4v006cdsc2kkl"} # default to in3s.com
DELEGATION_MIN=${GAIACLI_DELEGATION_MIN:-1000000} # minimum amount to delegate in bond_denom (COINs)
FEES=$([[ "x$GAIACLI_FEE" == "x" ]] || echo "--fees $GAIACLI_FEE") # GAIACLI_FEE must include denom, eg muon or uatom
FROM=${GAIACLI_FROM:-$(gaiacli keys list | fgrep -v NAME -m 1 | cut -f1)}
LOGGER=${GAIACLI_LOGGER:-"tee --append $0.log"} # stdout of gaiacli is piped into stdin of LOGGER
NAP=${GAIACLI_NAP:-86400} # in seconds
NODE=${GAIACLI_NODE:-"localhost:26657"}
PASSPHRASE=${GAIACLI_PASSWORD}
RESERVE=${GAIACLI_RESERVE:-200000} # COINs to keep just in case we need to pay fees in COINs
STRICT=${GAIACLI_STRICT:-1}
TZ=${GAIACLI_TZ:-"Europe/Andorra"} # time zone in which to report the awakening from NAP

[[ $STRICT && $DELEGATION_MIN -lt 1000000 ]] && echo "enforcing minimum delegation of 1000000 bond_denom so that power events appear in stargazer; GAIACLI_DELEGATION_MIN == $GAIACLI_DELEGATION_MIN" && exit -2
[[ "x$PASSPHRASE" == "x" ]] && echo -n "$FROM's password: " && read -s PASSPHRASE

ACCOUNT=$(gaiacli keys list | fgrep $FROM | cut -f3)
VALIDATOR=$(gaiacli keys show $FROM --bech=val | fgrep $FROM | cut -f3)
JSON=$(curl -s http://$NODE/genesis)
CHAIN=$(echo $JSON | jq -r .result.genesis.chain_id)
COIN=$(echo $JSON | jq -r .result.genesis.app_state.staking.params.bond_denom)
JSON=$(gaiacli query account $ACCOUNT --node $NODE --trust-node --output json)
JQ_VESTING=$(echo $JSON | fgrep -q BaseVestingAccount && echo ".BaseVestingAccount.BaseAccount" || echo "")

tx() {
   echo "$PASSPHRASE" | gaiacli tx $@ --from $FROM --chain-id $CHAIN --yes --trust-node $FEES --node $NODE --gas auto --gas-adjustment 1.1 --async --sequence $SEQUENCE | $LOGGER
   SEQUENCE=$(( $SEQUENCE + 1 ))
}

while true ; do
   JSON=$(gaiacli query account $ACCOUNT --node $NODE --trust-node --output json)
   SEQUENCE=$(echo $JSON | jq ".value$JQ_VESTING.sequence | tonumber" 2> /dev/null || echo 1)
   COINS=$(echo $JSON | jq ".value$JQ_VESTING.coins[] | select(.denom == \"$COIN\") | .amount | tonumber" 2> /dev/null || echo 0)
   REWARDS=$(gaiacli query distr rewards $ACCOUNT --node $NODE --trust-node --output json | jq -r ".[] | select(.denom == \"$COIN\") | .amount | tonumber | floor" 2> /dev/null || echo 0)
   DELEGATION=$(( $COINS + $REWARDS - $RESERVE ))
   VALOPER=$( ( gaiacli query staking validator $VALIDATOR --node $NODE --trust-node --output json 2> /dev/null || echo '{"operator_address":""}' ) | jq -r ".operator_address") ;

   [[ $DELEGATION -ge $DELEGATION_MIN ]] && tx staking delegate $DELEGATEE $DELEGATION$COIN || DELEGATION=0

   [[ $VALOPER == $VALIDATOR ]] && tx distr withdraw-rewards $VALIDATOR --commission

   HEIGHT=$(gaiacli status | jq -r ".sync_info.latest_block_height")
   TZ=$TZ date --date="$NAP seconds" +"HEIGHT == $HEIGHT; COINS == $COINS; REWARDS == $REWARDS; DELEGATION == $DELEGATION; NAP == $NAP; awaken %F %T %Z" | $LOGGER
   sleep $NAP # wait for NAP seconds
done
