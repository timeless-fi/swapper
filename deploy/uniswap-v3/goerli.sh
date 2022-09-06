# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/goerli.json
export RPC_URL=$RPC_URL_GOERLI

# load common utilities
. $(dirname $0)/../common.sh

# deploy contracts
univ3_swapper_address=$(deploy UniswapV3Swapper $ZEROEX_PROXY $WETH_GOERLI $PROTOCOL_FEE_GOERLI $UNIV3_FACTORY)
echo "UniswapV3Swapper=$univ3_swapper_address"

send $univ3_swapper_address "transferOwnership(address,bool,bool)" $INITIAL_OWNER_GOERLI true false
echo "UniswapV3SwapperOwner=$INITIAL_OWNER_GOERLI"

univ3_juggler_address=$(deploy UniswapV3Juggler $UNIV3_FACTORY $UNIV3_QUOTER)
echo "UniswapV3Juggler=$univ3_juggler_address"