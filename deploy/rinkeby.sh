# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/rinkeby.json
export RPC_URL=$RPC_URL_RINKEBY

# load common utilities
. $(dirname $0)/common.sh

# deploy contracts
univ3_swapper_address=$(deploy UniswapV3Swapper $ZEROEX_PROXY $WETH_RINKEBY $PROTOCOL_FEE_RINKEBY $UNIV3_FACTORY)
echo "UniswapV3Swapper=$univ3_swapper_address"

send $univ3_swapper_address "transferOwnership(address,bool,bool)" $INITIAL_OWNER_RINKEBY true false
echo "UniswapV3SwapperOwner=$INITIAL_OWNER_RINKEBY"

univ3_juggler_address=$(deploy UniswapV3Juggler $UNIV3_FACTORY $UNIV3_QUOTER)
echo "UniswapV3Juggler=$univ3_juggler_address"