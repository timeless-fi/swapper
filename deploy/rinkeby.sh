# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/rinkeby.json
export RPC_URL=$RPC_URL_RINKEBY

# load common utilities
. $(dirname $0)/common.sh

# deploy contracts
univ3_swapper_address=$(deploy UniswapV3Swapper $ZEROEX_PROXY_RINKEBY $UNIV3_FACTORY_RINKEBY)
echo "UniswapV3Swapper=$univ3_swapper_address"

univ3_juggler_address=$(deploy UniswapV3Juggler $UNIV3_FACTORY_RINKEBY $UNIV3_QUOTER_RINKEBY)
echo "UniswapV3Juggler=$univ3_juggler_address"