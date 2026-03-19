use std::{collections::HashMap, str::FromStr, sync::Arc};

use alloy::primitives::Address;
use tokio::{
    runtime::{Handle, Runtime},
    task::block_in_place,
};
use tycho_common::{
    models::{protocol::GetAmountOutParams, Chain},
    Bytes,
};

use crate::encoding::{
    errors::EncodingError,
    evm::{
        approvals::protocol_approvals_manager::ProtocolApprovalsManager,
        utils::{bytes_to_address, get_runtime},
    },
    models::{EncodingContext, Swap},
    swap_encoder::SwapEncoder,
};

/// Encodes a swap on Liquorice (RFQ) through the given executor address.
///
/// Liquorice uses a Request-for-Quote model where quotes are obtained off-chain
/// and settled on-chain. The executor receives pre-encoded calldata from the API.
///
/// # Fields
/// * `executor_address` - The address of the executor contract that will perform the swap.
/// * `balance_manager_address` - The address of the Liquorice balance manager contract.
#[derive(Clone)]
pub struct LiquoriceSwapEncoder {
    executor_address: Bytes,
    balance_manager_address: Bytes,
    runtime_handle: Handle,
    #[allow(dead_code)]
    runtime: Option<Arc<Runtime>>,
}

impl SwapEncoder for LiquoriceSwapEncoder {
    fn new(
        executor_address: Bytes,
        _chain: Chain,
        config: Option<HashMap<String, String>>,
    ) -> Result<Self, EncodingError> {
        let balance_manager_address = config
            .get("balance_manager_address")
            .ok_or_else(|| {
                EncodingError::FatalError(
                    "Missing liquorice balance manager address in config".to_string(),
                )
            })
            .and_then(|s| {
                Bytes::from_str(s).map_err(|_| {
                    EncodingError::FatalError(
                        "Invalid liquorice balance manager address".to_string(),
                    )
                })
            })?;

        let (runtime_handle, runtime) = get_runtime()?;
        Ok(Self { executor_address, balance_manager_address, runtime_handle, runtime })
    }

    fn encode_swap(
        &self,
        swap: &Swap,
        encoding_context: &EncodingContext,
    ) -> Result<Vec<u8>, EncodingError> {
        let token_in = bytes_to_address(swap.token_in())?;
        let token_out = bytes_to_address(swap.token_out())?;

        // Get protocol state and request signed quote
        let protocol_state = swap
            .get_protocol_state()
            .as_ref()
            .ok_or_else(|| {
                EncodingError::FatalError("protocol_state is required for Liquorice".to_string())
            })?;

        let estimated_amount_in = swap
            .get_estimated_amount_in()
            .clone()
            .ok_or(EncodingError::FatalError(
                "Estimated amount in is mandatory for a Liquorice swap".to_string(),
            ))?;

        let router_address = encoding_context
            .router_address
            .clone()
            .ok_or(EncodingError::FatalError(
                "The router address is needed to perform a Liquorice swap".to_string(),
            ))?;

        let params = GetAmountOutParams {
            amount_in: estimated_amount_in.clone(),
            token_in: swap.token_in().clone(),
            token_out: swap.token_out().clone(),
            sender: router_address.clone(),
            receiver: encoding_context.receiver.clone(),
        };

        let signed_quote = block_in_place(|| {
            self.runtime_handle.block_on(async {
                protocol_state
                    .as_indicatively_priced()?
                    .request_signed_quote(params)
                    .await
            })
        })?;

        // Extract required fields from quote
        let liquorice_calldata = signed_quote
            .quote_attributes
            .get("calldata")
            .ok_or(EncodingError::FatalError(
                "Liquorice quote must have a calldata attribute".to_string(),
            ))?;

        let base_token_amount = signed_quote
            .quote_attributes
            .get("base_token_amount")
            .ok_or(EncodingError::FatalError(
                "Liquorice quote must have a base_token_amount attribute".to_string(),
            ))?;

        // Get partial fill offset (defaults to 0 if not present, meaning partial fill is not
        // available for the quote)
        let partial_fill_offset: Vec<u8> = signed_quote
            .quote_attributes
            .get("partial_fill_offset")
            .map(|b| {
                if b.len() == 4 {
                    b.to_vec()
                } else {
                    // Pad to 4 bytes if needed
                    let mut padded = vec![0u8; 4];
                    if b.len() < 4 {
                        let start = 4 - b.len();
                        padded[start..].copy_from_slice(b);
                    }
                    padded
                }
            })
            .unwrap_or(vec![0u8; 4]);

        // Get min base token amount (defaults to original base token amount if partial fill is not
        // available for the quote)
        let min_base_token_amount = signed_quote
            .quote_attributes
            .get("min_base_token_amount")
            .unwrap_or(base_token_amount);

        // Parse original base token amount (U256 encoded as 32 bytes)
        let original_base_token_amount = if base_token_amount.len() == 32 {
            base_token_amount.to_vec()
        } else {
            // Pad to 32 bytes if needed
            let mut padded = vec![0u8; 32];
            let start = 32 - base_token_amount.len();
            padded[start..].copy_from_slice(base_token_amount);
            padded
        };

        // Parse min base token amount (U256 encoded as 32 bytes)
        let min_base_token_amount = if min_base_token_amount.len() == 32 {
            min_base_token_amount.to_vec()
        } else {
            let mut padded = vec![0u8; 32];
            let start = 32 - min_base_token_amount.len();
            padded[start..].copy_from_slice(min_base_token_amount);
            padded
        };

        // Check if approval is needed from Router to balance manager
        let router_address = bytes_to_address(&router_address)?;
        let balance_manager_address = Address::from_slice(&self.balance_manager_address);
        let approval_needed = ProtocolApprovalsManager::new()?.approval_needed(
            token_in,
            router_address,
            balance_manager_address,
        )?;

        let receiver = bytes_to_address(&encoding_context.receiver)?;

        // Encode packed data for the executor
        // Format: token_in | token_out | transfer_type | partial_fill_offset |
        //         original_base_token_amount | min_base_token_amount |
        //         approval_needed | receiver | liquorice_calldata
        let mut encoded = Vec::new();

        encoded.extend_from_slice(token_in.as_slice()); // 20 bytes
        encoded.extend_from_slice(token_out.as_slice()); // 20 bytes
        encoded.push(encoding_context.transfer_type as u8); // 1 byte
        encoded.extend_from_slice(&partial_fill_offset); // 4 bytes
        encoded.extend_from_slice(&original_base_token_amount); // 32 bytes
        encoded.extend_from_slice(&min_base_token_amount); // 32 bytes
        encoded.push(approval_needed as u8); // 1 byte
        encoded.extend_from_slice(receiver.as_slice()); // 20 bytes

        // Calldata (variable length)
        encoded.extend_from_slice(liquorice_calldata);

        Ok(encoded)
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
    use std::str::FromStr;

    use alloy::hex::encode;
    use num_bigint::BigUint;
    use tycho_common::models::protocol::ProtocolComponent;

    use super::*;
    use crate::encoding::{
        evm::{
            swap_encoder::liquorice::LiquoriceSwapEncoder, testing_utils::MockRFQState,
            utils::biguint_to_u256,
        },
        models::TransferType,
    };

    fn liquorice_config() -> Option<HashMap<String, String>> {
        Some(HashMap::from([(
            "balance_manager_address".to_string(),
            "0xb87bAE43a665EB5943A5642F81B26666bC9E5C95".to_string(),
        )]))
    }

    #[test]
    fn test_encode_liquorice_single_with_protocol_state() {
        // 3000 USDC -> 1 WETH using a mocked RFQ state to get a quote
        let quote_amount_out = BigUint::from_str("1000000000000000000").unwrap();
        let liquorice_calldata = Bytes::from_str("0xdeadbeef1234567890").unwrap();
        let base_token_amount = biguint_to_u256(&BigUint::from(3000000000_u64))
            .to_be_bytes::<32>()
            .to_vec();

        let liquorice_component = ProtocolComponent {
            id: String::from("liquorice-rfq"),
            protocol_system: String::from("rfq:liquorice"),
            ..Default::default()
        };

        let min_base_token_amount = biguint_to_u256(&BigUint::from(2500000000_u64))
            .to_be_bytes::<32>()
            .to_vec();

        let liquorice_state = MockRFQState {
            quote_amount_out,
            quote_data: HashMap::from([
                ("calldata".to_string(), liquorice_calldata.clone()),
                ("base_token_amount".to_string(), Bytes::from(base_token_amount.clone())),
                ("min_base_token_amount".to_string(), Bytes::from(min_base_token_amount.clone())),
                ("partial_fill_offset".to_string(), Bytes::from(vec![12u8])),
            ]),
        };

        let token_in = Bytes::from("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"); // USDC
        let token_out = Bytes::from("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"); // WETH

        let swap = Swap::new(liquorice_component, token_in.clone(), token_out.clone())
            .estimated_amount_in(BigUint::from_str("3000000000").unwrap())
            .protocol_state(Arc::new(liquorice_state));

        let encoding_context = EncodingContext {
            receiver: Bytes::from("0xc5564C13A157E6240659fb81882A28091add8670"),
            exact_out: false,
            router_address: Some(Bytes::zero(20)),
            group_token_in: token_in.clone(),
            group_token_out: token_out.clone(),
            transfer_type: TransferType::Transfer,
            historical_trade: false,
        };

        let encoder = LiquoriceSwapEncoder::new(
            Bytes::from("0x543778987b293C7E8Cf0722BB2e935ba6f4068D4"),
            Chain::Ethereum,
            liquorice_config(),
        )
        .unwrap();

        let encoded_swap = encoder
            .encode_swap(&swap, &encoding_context)
            .unwrap();
        let hex_swap = encode(&encoded_swap);

        // Expected format:
        // token_in (20) | token_out (20) | transfer_type (1) | partial_fill_offset (4) |
        // original_base_token_amount (32) | min_base_token_amount (32) |
        // approval_needed (1) | receiver (20) | calldata (variable)
        let expected_swap = String::from(concat!(
            // token_in (USDC)
            "a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            // token_out (WETH)
            "c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
            // transfer_type
            "01",
            // partial_fill_offset
            "0000000c",
            // original_base_token_amount (3000000000 as U256)
            "00000000000000000000000000000000000000000000000000000000b2d05e00",
            // min_base_token_amount (2500000000 as U256)
            "000000000000000000000000000000000000000000000000000000009502f900",
            // approval_needed
            "01",
            // receiver
            "c5564c13a157e6240659fb81882a28091add8670",
        ));
        assert_eq!(hex_swap, expected_swap + &liquorice_calldata.to_string()[2..]);
    }
}
