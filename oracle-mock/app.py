from web3 import Web3
from eth_typing import HexStr
from eth_utils import to_bytes
import json
import os
from dotenv import load_dotenv
import time

# Load environment variables
load_dotenv()

rpc_url = os.getenv('RPC_URL')
private_key = os.getenv('PRIVATE_KEY')
marketplace_address = os.getenv('MARKETPLACE_ADDRESS')
usdc_address = os.getenv('USDC_ADDRESS')
marketplace_abi_path = os.getenv('MARKETPLACE_ABI_PATH')
usdc_abi_path = os.getenv('USDC_ABI_PATH')

if not all([rpc_url, private_key, marketplace_address, usdc_address, 
            marketplace_abi_path, usdc_abi_path]):
    raise ValueError("Missing required environment variables")

# Connect to the network
w3 = Web3(Web3.HTTPProvider(rpc_url))

# Load contract ABIs
try:
    with open(marketplace_abi_path) as f:
        marketplace_abi = json.load(f)['abi']
    with open(usdc_abi_path) as f:
        usdc_abi = json.load(f)['abi']
except FileNotFoundError as e:
    raise FileNotFoundError(f"ABI file not found: {e}")

# Initialize contract instances
marketplace_contract = w3.eth.contract(address=marketplace_address, abi=marketplace_abi)
usdc_contract = w3.eth.contract(address=usdc_address, abi=usdc_abi)

# Create account from private key
owner = w3.eth.account.from_key(private_key)

def get_campaign_info(campaign_id: bytes):
    try:
        return marketplace_contract.functions.getCampaignInfo(campaign_id).call()
    except Exception as e:
        raise Exception(f"Transaction failed: {str(e)}")
        
def accept_campaign(campaign_id: bytes):
    try:
        current_nonce = w3.eth.get_transaction_count(owner.address)
        accept_txn = marketplace_contract.functions.acceptProjectCampaign(campaign_id).build_transaction({
            'from': owner.address, 'nonce': current_nonce, 'gas': 100000, 'gasPrice': w3.eth.gas_price
        })
        sign_and_send_txn(accept_txn)
        print(f"Accepted campaign {campaign_id.hex()}") 
    except Exception as e:
        raise Exception(f"Transaction failed: {str(e)}")

def handle_campaign(campaign_id: bytes):
    try:
        campaign_info = get_campaign_info(campaign_id)
        creator = campaign_info[2]
        kol = campaign_info[3]
        full_amount = campaign_info[6] * 10 ** 6
        amount = int(full_amount * 0.9) * 10 ** 6
        status = campaign_info[7]
        current_nonce = w3.eth.get_transaction_count(owner.address)

        if status == 1:  # ACCEPTED → Fulfill & Transfer Funds from Owner to Kol
            fulfill_txn = marketplace_contract.functions.fulfilProjectCampaign(campaign_id).build_transaction({
                'from': owner.address, 'nonce': current_nonce, 'gas': 200000, 'gasPrice': w3.eth.gas_price
            })
            sign_and_send_txn(fulfill_txn)
            
            transfer_txn = usdc_contract.functions.transfer(kol, amount).build_transaction({
                'from': owner.address, 'nonce': current_nonce + 1, 'gas': 100000, 'gasPrice': w3.eth.gas_price
            })
            sign_and_send_txn(transfer_txn)
            print(f"Transferred {amount} USDC to {kol}")
        
        elif status == 0 and w3.eth.get_block('latest').timestamp > campaign_info[4]:  # OPEN → Expired → Discard & Transfer Funds from Owner to Creator
            discard_txn = marketplace_contract.functions.discardCampaign(campaign_id).build_transaction({
                'from': owner.address, 'nonce': current_nonce, 'gas': 100000, 'gasPrice': w3.eth.gas_price
            })
            sign_and_send_txn(discard_txn)

            transfer_txn = usdc_contract.functions.transfer(creator, full_amount).build_transaction({
                'from': owner.address, 'nonce': current_nonce + 1, 'gas': 100000, 'gasPrice': w3.eth.gas_price
            })
            sign_and_send_txn(transfer_txn)
            print(f"Transferred {full_amount} USDC to {creator}")
            
            print(f"Discarded expired campaign {campaign_id.hex()}")
        
        elif status == 1 and w3.eth.get_block('latest').timestamp > campaign_info[5]:  # ACCEPTED → Expired → Unfulfill & Transfer Funds from Owner to Creator
            unfulfill_txn = marketplace_contract.functions.unfulfillCampaign(campaign_id).build_transaction({
                'from': owner.address, 'nonce': current_nonce, 'gas': 100000, 'gasPrice': w3.eth.gas_price
            })
            sign_and_send_txn(unfulfill_txn)
            print(f"Marked campaign {campaign_id.hex()} as unfulfilled")

            transfer_txn = usdc_contract.functions.transfer(creator, full_amount).build_transaction({
                'from': owner.address, 'nonce': current_nonce + 1, 'gas': 100000, 'gasPrice': w3.eth.gas_price
            })
            sign_and_send_txn(transfer_txn)
            print(f"Transferred {full_amount} USDC to {creator}")

    except Exception as e:
        raise Exception(f"Error handling campaign {campaign_id.hex()}: {str(e)}")
        
def sign_and_send_txn(txn: dict):
    signed_txn = w3.eth.account.sign_transaction(txn, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed_txn.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    return receipt

def process_campaigns():
    try:
        all_campaigns = marketplace_contract.functions.getAllCampaigns().call()
        for campaign_id in all_campaigns:
            handle_campaign(campaign_id)
    except Exception as e:
        raise Exception(f"Error processing campaigns: {str(e)}")

if __name__ == "__main__":
    # all_campaigns = marketplace_contract.functions.getAllCampaigns().call()
    # accept_campaign(all_campaigns[0])

    while True:
        print("\n\nProcessing campaigns...")
        process_campaigns()
        print("Campaigns processed")
        print("Sleeping for 10 seconds...")
        print("--------------------------------")
        time.sleep(10)
