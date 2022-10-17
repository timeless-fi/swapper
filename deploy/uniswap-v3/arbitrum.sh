# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/arbitrum.json
export RPC_URL=$RPC_URL_ARBITRUM

# load common utilities
. $(dirname $0)/../common.sh

# deploy contracts
univ3_swapper_address=$(deploy UniswapV3Swapper $ZEROEX_PROXY $WETH_ARBITRUM $PROTOCOL_FEE_ARBITRUM $UNIV3_FACTORY)
echo "UniswapV3Swapper=$univ3_swapper_address"

send $univ3_swapper_address "transferOwnership(address,bool,bool)" $INITIAL_OWNER_ARBITRUM true false
echo "UniswapV3SwapperOwner=$INITIAL_OWNER_ARBITRUM"

univ3_juggler_address=$(deploy UniswapV3Juggler $UNIV3_FACTORY $UNIV3_QUOTER)
echo "UniswapV3Juggler=$univ3_juggler_address"