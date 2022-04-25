# load environment variables from .env
source .env

# set env variables
export ADDRESSES_FILE=./deployments/mainnet.json
export RPC_URL=$RPC_URL_MAINNET

# load common utilities
. $(dirname $0)/common.sh

# deploy contracts
univ3_swapper_address=$(deploy UniswapV3Swapper $ZEROEX_PROXY $UNIV3_FACTORY)
echo "UniswapV3Swapper=$univ3_swapper_address"

univ3_juggler_address=$(deploy UniswapV3Juggler $UNIV3_FACTORY $UNIV3_QUOTER)
echo "UniswapV3Juggler=$univ3_juggler_address"