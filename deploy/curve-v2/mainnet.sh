# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/mainnet.json
export RPC_URL=$RPC_URL_MAINNET

# load common utilities
. $(dirname $0)/../common.sh

# deploy contracts
swapper_address=$(deploy CurveV2Swapper $ZEROEX_PROXY $WETH_MAINNET $PROTOCOL_FEE_MAINNET)
echo "CurveV2Swapper=$swapper_address"

send $swapper_address "transferOwnership(address,bool,bool)" $INITIAL_OWNER_MAINNET true false
echo "CurveV2SwapperOwner=$INITIAL_OWNER_MAINNET"

juggler_address=$(deployNoArgs CurveV2Juggler)
echo "CurveV2Juggler=$juggler_address"