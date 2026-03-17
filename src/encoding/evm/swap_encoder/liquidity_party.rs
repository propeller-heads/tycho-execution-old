use std::{collections::HashMap, str::FromStr};

use alloy::sol_types::SolValue;
use tycho_common::{
    models::{Address, Chain},
    Bytes,
};

use crate::encoding::{
    errors::EncodingError,
    evm::utils::bytes_to_address,
    models::{EncodingContext, Swap},
    swap_encoder::SwapEncoder,
};

/// Encodes a swap on a Liquidity Party pool through the given executor address.
///
/// # Fields
/// * `executor_address` - The address of the executor contract that will perform the swap.
#[derive(Clone)]
pub struct LiquidityPartySwapEncoder {
    executor_address: Bytes,
}

impl LiquidityPartySwapEncoder {
    fn get_token_indexes(&self, swap: &Swap) -> Result<(Bytes, u8, u8), EncodingError> {
        let token_addresses: &Vec<Address> = &swap.component().tokens;
        let token_in = swap.token_in();
        let token_out = swap.token_out();

        let token_in_idx = token_addresses
            .iter()
            .position(|addr| addr == token_in)
            .ok_or(EncodingError::FatalError("Token in not found in pool tokens".to_string()))?;

        let token_out_idx = token_addresses
            .iter()
            .position(|addr| addr == token_out)
            .ok_or(EncodingError::FatalError("Token out not found in pool tokens".to_string()))?;

        Ok((token_in.clone(), token_in_idx as u8, token_out_idx as u8))
    }
}

impl SwapEncoder for LiquidityPartySwapEncoder {
    fn new(
        executor_address: Bytes,
        _chain: Chain,
        _config: Option<HashMap<String, String>>,
    ) -> Result<Self, EncodingError> {
        Ok(Self { executor_address })
    }

    fn encode_swap(
        &self,
        swap: &Swap,
        encoding_context: &EncodingContext,
    ) -> Result<Vec<u8>, EncodingError> {
        let pool_addr = Address::from_str(&swap.component().id).map_err(|_| {
            EncodingError::FatalError("LiqP swap encoder: invalid component id".to_string())
        })?;

        let (token_in, token_in_idx, token_out_idx) = self.get_token_indexes(swap)?;

        let args = (
            bytes_to_address(&pool_addr)?,
            bytes_to_address(&token_in)?,
            token_in_idx.to_be_bytes(),
            token_out_idx.to_be_bytes(),
            bytes_to_address(&encoding_context.receiver)?,
            (encoding_context.transfer_type as u8).to_be_bytes(),
        );

        Ok(args.abi_encode_packed())
    }

    fn executor_address(&self) -> &Bytes {
        &self.executor_address
    }

    fn clone_box(&self) -> Box<dyn SwapEncoder> {
        Box::new(self.clone())
    }
}

#[cfg(test)]
mod tests {
    use alloy::hex::encode;
    use tycho_common::models::protocol::ProtocolComponent;

    use super::*;
    use crate::encoding::{evm::utils::write_calldata_to_file, models::TransferType};
    #[test]
    fn test_encode_liquidityparty() {
        let liqp_pool = ProtocolComponent {
            // mainnet test
            id: String::from("0xfA0be6148F66A6499666cf790d647D00daB76904"),
            tokens: [
                Address::from("0xdAC17F958D2ee523a2206206994597C13D831ec7"),
                Address::from("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
                Address::from("0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599"),
                Address::from("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
                Address::from("0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"),
                Address::from("0xD31a59c85aE9D8edEFeC411D448f90841571b89c"),
                Address::from("0x50327c6c5a14DCaDE707ABad2E27eB517df87AB5"),
                Address::from("0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"),
                Address::from("0x6982508145454Ce325dDbE47a25d4ec3d2311933"),
                Address::from("0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE"),
            ]
            .to_vec(),
            ..Default::default()
        };
        // Pool Tokens:
        // [0xdAC17F958D2ee523a2206206994597C13D831ec7, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
        // 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
        // 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, 0xD31a59c85aE9D8edEFeC411D448f90841571b89c,
        // 0x50327c6c5a14DCaDE707ABad2E27eB517df87AB5, 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9,
        // 0x6982508145454Ce325dDbE47a25d4ec3d2311933, 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE]

        let token_in = Bytes::from("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"); // USDC
        let token_out = Bytes::from("0xD31a59c85aE9D8edEFeC411D448f90841571b89c"); // WSOL
        let swap = Swap::new(liqp_pool, token_in.clone(), token_out.clone());
        let encoding_context = EncodingContext {
            receiver: Bytes::from("0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e"), // BOB
            exact_out: false,
            router_address: Some(Bytes::zero(20)),
            group_token_in: token_in.clone(),
            group_token_out: token_out.clone(),
            transfer_type: TransferType::Transfer,
            historical_trade: false,
        };
        let encoder = LiquidityPartySwapEncoder::new(
            Bytes::from("0x543778987b293C7E8Cf0722BB2e935ba6f4068D4"), /* What is this address?
                                                                        * It is used in all the
                                                                        * tests in place of the
                                                                        * router address */
            Chain::Ethereum,
            None,
        )
        .unwrap();
        let encoded_swap = encoder
            .encode_swap(&swap, &encoding_context)
            .unwrap();
        let hex_swap = encode(&encoded_swap);
        assert_eq!(
            hex_swap,
            String::from(concat!(
                // pool address
                "fa0be6148f66a6499666cf790d647d00dab76904", // MUST BE LOWERCASE, NO 0x
                // in token address
                "a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", // MUST BE LOWERCASE, NO 0x
                // in token index
                "01",
                // out token index
                "05",
                // receiver
                "1d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e", // Bob, MUST BE LOWERCASE, NO 0x
                // transfer type Transfer
                "01",
            ))
        );
        write_calldata_to_file("test_encode_liquidityparty", hex_swap.as_str());
    }
}
