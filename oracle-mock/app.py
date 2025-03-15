from web3 import Web3
import json
import os
from dotenv import load_dotenv
import time
import requests

# Load environment variables
load_dotenv()

rpc_url = os.getenv('BASE_ALCHEMY_RPC_URL')
private_key = os.getenv('BASE_PRIVATE_KEY')
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

def get_campaign_info(campaign_id: int):
    try:
        campaign_info = marketplace_contract.functions.getCampaignInfo(campaign_id).call()
        return campaign_info
    except Exception as e:
        raise Exception(f"Transaction failed: {str(e)}")

def discard_campaign(campaign_id: int):
    try:
        url = f"{os.getenv('BASE_URL')}/update-campaign"
        headers = {
            "Content-Type": "application/json",
            "x-api-key": os.getenv('TEST_API_KEY'),
            "source": os.getenv('SOURCE')
        }
        body = {
            "campaign_id": campaign_id,
            "status": 'discarded'
        }
        response = requests.post(url, json=body, headers=headers)
        return response.json()
    except Exception as e:
        raise Exception(f"Error discarding campaign {campaign_id}: {str(e)}")

def handle_campaign(campaign_id: int):
    print(f"\n\nProcessing campaign {campaign_id}")
    try:
        # get campaign info
        campaign_info = get_campaign_info(campaign_id)
        print(f"Campaign info: {campaign_info}")
        
        # extract data
        status = campaign_info[7]
        current_nonce = w3.eth.get_transaction_count(owner.address)


        if status == 0:  # OPEN 
            # check for the offer time and curretn time
            offer_time = int(campaign_info[4] / 1000)  # Convert ms to sec
            # current_time = w3.eth.get_block('latest').timestamp
            current_time = int(time.time())
            print(f"Offer time: {offer_time}, Current time: {current_time}")

            if current_time > offer_time:
                # discard the campaign
                discard_txn = marketplace_contract.functions.discardCampaign(campaign_id).build_transaction({
                    'from': owner.address, 'nonce': current_nonce, 'gas': 100000, 'gasPrice': w3.eth.gas_price
                })
                sign_and_send_txn(discard_txn)
                print(f"Discarded campaign as offer time ended {campaign_id}")
                discard_campaign(campaign_id)
            else:
                print(f"Offer time not ended for campaign {campaign_id}\n\n")
                
        elif status == 1:  # ACCEPTED 
            promotion_end_time = int(campaign_info[5] / 1000) 
            # current_time = w3.eth.get_block('latest').timestamp
            current_time = int(time.time())
            print(f"Promotion end time: {promotion_end_time}, Current time: {current_time}")
            if current_time > promotion_end_time:
                # fulfill the campaign
                discard_txn = marketplace_contract.functions.discardCampaign(campaign_id).build_transaction({
                    'from': owner.address, 'nonce': current_nonce, 'gas': 100000, 'gasPrice': w3.eth.gas_price
                })
                sign_and_send_txn(discard_txn)
                print(f"Discarded campaign as promotion ended {campaign_id}")
                discard_campaign(campaign_id)
            else:
                print(f"Promotion not ended for campaign {campaign_id}")

    except Exception as e:
        print(f"Error handling campaign {campaign_id}: {str(e)}")
        print(f"Campaign info: {campaign_info}")
        print("--------------------------------\n\n")
        # raise Exception(f"Error handling campaign {campaign_id}: {str(e)}")

def sign_and_send_txn(txn: dict):
    signed_txn = w3.eth.account.sign_transaction(txn, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed_txn.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    return receipt

def process_campaigns():
    try:
        url = f"{os.getenv('BASE_URL')}/get-all-campaigns"
        headers = {
            "Content-Type": "application/json",
            "x-api-key": os.getenv('TEST_API_KEY'),
            "source": os.getenv('SOURCE')
        }
        response = requests.get(url, headers=headers)
        all_campaigns = response.json().get('result')

        for campaign_id in all_campaigns:
            handle_campaign(campaign_id)

    except Exception as e:
        raise Exception(f"Error processing campaigns: {str(e)}")

if __name__ == "__main__":

    while True:
        print("\n\nProcessing campaigns...")
        process_campaigns()
        print("Campaigns processed")
        print("Sleeping for 60 seconds...")
        print("--------------------------------")
        time.sleep(60)
