use starknet::{ContractAddress, get_caller_address, get_contract_address};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin::token::erc721::interface::{IERC721Dispatcher, IERC721DispatcherTrait};
use core::array::ArrayTrait;

#[derive(Drop, Copy, Serde, starknet::Store)]
struct IPUsageRights {
    commercial_use: bool,
    modifications_allowed: bool,
    attribution_required: bool,
    geographic_restrictions: felt252,
    usage_duration: u64,
    sublicensing_allowed: bool,
    industry_restrictions: felt252,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
struct DerivativeRights {
    allowed: bool,
    royalty_share: u16,
    requires_approval: bool,
    max_derivatives: u32,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
struct IPMetadata {
    ipfs_hash: felt252,
    license_terms: felt252,
    creator: ContractAddress,
    creation_date: u64,
    last_updated: u64,
    version: u32,
    content_type: felt252,
    derivative_of: u256,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
struct Listing {
    seller: ContractAddress,
    price: u256,
    currency: ContractAddress,
    active: bool,
    metadata: IPMetadata,
    royalty_percentage: u16,
    usage_rights: IPUsageRights,
    derivative_rights: DerivativeRights,
    minimum_purchase_duration: u64,
    bulk_discount_rate: u16,
}

#[derive(Drop, starknet::Event)]
struct ItemListed {
    #[key]
    token_id: u256,
    seller: ContractAddress,
    price: u256,
    currency: ContractAddress,
}

#[derive(Drop, starknet::Event)]
struct ItemUnlisted {
    #[key]
    token_id: u256,
}

#[derive(Drop, starknet::Event)]
struct ItemSold {
    #[key]
    token_id: u256,
    seller: ContractAddress,
    buyer: ContractAddress,
    price: u256,
}

#[derive(Drop, starknet::Event)]
struct ListingUpdated {
    #[key]
    token_id: u256,
    new_price: u256,
}

#[derive(Drop, starknet::Event)]
struct MetadataUpdated {
    #[key]
    token_id: u256,
    new_metadata_hash: felt252,
    new_license_terms_hash: felt252,
    updater: ContractAddress,
}

#[derive(Drop, starknet::Event)]
struct DerivativeRegistered {
    #[key]
    token_id: u256,
    parent_token_id: u256,
    creator: ContractAddress,
}

#[starknet::interface]
trait IIPMarketplace<TContractState> {
    fn list_item(
        ref self: TContractState,
        token_id: u256,
        price: u256,
        currency_address: ContractAddress,
        metadata_hash: felt252,
        license_terms_hash: felt252,
        usage_rights: IPUsageRights,
        derivative_rights: DerivativeRights,
    );
    fn unlist_item(ref self: TContractState, token_id: u256);
    fn buy_item(ref self: TContractState, token_id: u256);
    fn update_listing(ref self: TContractState, token_id: u256, new_price: u256);
    fn get_listing(self: @TContractState, token_id: u256) -> Listing;
    fn update_metadata(
        ref self: TContractState,
        token_id: u256,
        new_metadata_hash: felt252,
        new_license_terms_hash: felt252,
    );
    fn register_derivative(
        ref self: TContractState,
        parent_token_id: u256,
        metadata_hash: felt252,
        license_terms_hash: felt252,
    ) -> u256;
}

#[starknet::contract]
mod IPMarketplace {
    use super::{
        IPUsageRights, DerivativeRights, IPMetadata, Listing,
        ItemListed, ItemUnlisted, ItemSold, ListingUpdated, MetadataUpdated, DerivativeRegistered,
        IERC20Dispatcher, IERC20DispatcherTrait, IERC721Dispatcher, IERC721DispatcherTrait, 
        ArrayTrait, ContractAddress, get_caller_address, get_contract_address
    };

    #[storage]
    struct Storage {
        listings: starknet::storage::Map::<u256, Listing>,
        derivative_registry: starknet::storage::Map::<u256, u256>,
        nft_contract: ContractAddress,
        owner: ContractAddress,
        marketplace_fee: u256,
        next_token_id: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ItemListed: ItemListed,
        ItemUnlisted: ItemUnlisted,
        ItemSold: ItemSold,
        ListingUpdated: ListingUpdated,
        MetadataUpdated: MetadataUpdated,
        DerivativeRegistered: DerivativeRegistered,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        nft_contract_address: ContractAddress,
        marketplace_fee: u256
    ) {
        self.nft_contract.write(nft_contract_address);
        self.owner.write(get_caller_address());
        self.marketplace_fee.write(marketplace_fee);
        self.next_token_id.write(0);
    }

    #[abi(embed_v0)]
    impl IPMarketplaceImpl of super::IIPMarketplace<ContractState> {
        fn list_item(
            ref self: ContractState,
            token_id: u256,
            price: u256,
            currency_address: ContractAddress,
            metadata_hash: felt252,
            license_terms_hash: felt252,
            usage_rights: IPUsageRights,
            derivative_rights: DerivativeRights,
        ) {
            let caller = get_caller_address();
            let nft_contract = IERC721Dispatcher { contract_address: self.nft_contract.read() };
            
            // Verify ownership
            assert(nft_contract.owner_of(token_id) == caller, 'Not token owner');
            
            // Verify approval
            assert(
                nft_contract.get_approved(token_id) == get_contract_address() 
                || nft_contract.is_approved_for_all(caller, get_contract_address()),
                'Not approved for marketplace'
            );

            let metadata = IPMetadata {
                ipfs_hash: metadata_hash,
                license_terms: license_terms_hash,
                creator: caller,
                creation_date: starknet::get_block_timestamp(),
                last_updated: starknet::get_block_timestamp(),
                version: 1,
                content_type: 0,
                derivative_of: 0,
            };

            let listing = Listing {
                seller: caller,
                price,
                currency: currency_address,
                active: true,
                metadata,
                royalty_percentage: 250, // 2.5%
                usage_rights,
                derivative_rights,
                minimum_purchase_duration: 0,
                bulk_discount_rate: 0,
            };

            self.listings.write(token_id, listing);

            self.emit(Event::ItemListed(ItemListed {
                token_id,
                seller: caller,
                price,
                currency: currency_address,
            }));
        }

        fn unlist_item(ref self: ContractState, token_id: u256) {
            let caller = get_caller_address();
            let mut listing = self.listings.read(token_id);
            
            assert(listing.active, 'Listing not active');
            assert(listing.seller == caller, 'Not the seller');

            listing.active = false;
            self.listings.write(token_id, listing);

            self.emit(Event::ItemUnlisted(ItemUnlisted { token_id }));
        }

        fn buy_item(ref self: ContractState, token_id: u256) {
            let caller = get_caller_address();
            let listing = self.listings.read(token_id);
            
            assert(listing.active, 'Listing not active');
            assert(caller != listing.seller, 'Seller cannot buy');

            let currency = IERC20Dispatcher { contract_address: listing.currency };
            let fee = (listing.price * self.marketplace_fee.read()) / 10000;
            let seller_amount = listing.price - fee;

            // Process payments
            currency.transfer_from(caller, listing.seller, seller_amount);
            currency.transfer_from(caller, self.owner.read(), fee);

            // Transfer NFT
            let nft_contract = IERC721Dispatcher { contract_address: self.nft_contract.read() };
            nft_contract.transfer_from(listing.seller, caller, token_id);

            // Update listing
            let mut updated_listing = listing;
            updated_listing.active = false;
            self.listings.write(token_id, updated_listing);

            self.emit(Event::ItemSold(ItemSold {
                token_id,
                seller: listing.seller,
                buyer: caller,
                price: listing.price,
            }));
        }

        fn update_listing(ref self: ContractState, token_id: u256, new_price: u256) {
            let caller = get_caller_address();
            let mut listing = self.listings.read(token_id);
            
            assert(listing.active, 'Listing not active');
            assert(listing.seller == caller, 'Not the seller');

            listing.price = new_price;
            self.listings.write(token_id, listing);

            self.emit(Event::ListingUpdated(ListingUpdated {
                token_id,
                new_price,
            }));
        }

        fn get_listing(self: @ContractState, token_id: u256) -> Listing {
            self.listings.read(token_id)
        }

        fn update_metadata(
            ref self: ContractState,
            token_id: u256,
            new_metadata_hash: felt252,
            new_license_terms_hash: felt252,
        ) {
            let caller = get_caller_address();
            let mut listing = self.listings.read(token_id);
            assert(listing.metadata.creator == caller, 'Not the creator');

            listing.metadata.ipfs_hash = new_metadata_hash;
            listing.metadata.license_terms = new_license_terms_hash;
            listing.metadata.last_updated = starknet::get_block_timestamp();
            listing.metadata.version += 1;

            self.listings.write(token_id, listing);

            self.emit(Event::MetadataUpdated(MetadataUpdated {
                token_id,
                new_metadata_hash,
                new_license_terms_hash,
                updater: caller,
            }));
        }

        fn register_derivative(
            ref self: ContractState,
            parent_token_id: u256,
            metadata_hash: felt252,
            license_terms_hash: felt252,
        ) -> u256 {
            let caller = get_caller_address();
            let parent_listing = self.listings.read(parent_token_id);
            
            assert(parent_listing.derivative_rights.allowed, 'Derivatives not allowed');
            assert(parent_listing.active, 'Parent listing not active');

            let new_token_id = self.next_token_id.read() + 1;
            self.next_token_id.write(new_token_id);

            self.derivative_registry.write(new_token_id, parent_token_id);

            self.emit(Event::DerivativeRegistered(DerivativeRegistered {
                token_id: new_token_id,
                parent_token_id,
                creator: caller,
            }));

            new_token_id
        }
    }
}