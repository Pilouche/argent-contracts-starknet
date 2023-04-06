#[account_contract]
mod ArgentMultisigAccount {
    use array::ArrayTrait;
    use array::SpanTrait;
    use box::BoxTrait;
    use ecdsa::check_ecdsa_signature;
    use option::OptionTrait;
    use traits::Into;
    use zeroable::Zeroable;

    use starknet::get_contract_address;
    use starknet::ContractAddressIntoFelt252;
    use starknet::VALIDATED;

    use lib::assert_only_self;
    use lib::assert_no_self_call;
    use lib::check_enough_gas;
    use lib::Call;
    use lib::Version;
    use multisig::deserialize_array_signer_signature;
    use multisig::spans;
    use multisig::MultisigStorage;
    use multisig::SignerSignature;
    use multisig::SignerSignatureSize;

    const ERC165_IERC165_INTERFACE_ID: felt252 = 0x01ffc9a7;
    const ERC165_ACCOUNT_INTERFACE_ID: felt252 = 0xa66bd575;
    const ERC165_OLD_ACCOUNT_INTERFACE_ID: felt252 = 0x3943f10f;

    const EXECUTE_AFTER_UPGRADE_SELECTOR: felt252 =
        738349667340360233096752603318170676063569407717437256101137432051386874767;

    const NAME: felt252 = 'ArgentMultisig';

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                           Events                                           //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[event]
    fn ConfigurationUpdated(
        new_threshold: usize,
        new_signers_count: usize,
        added_signers: Array<felt252>,
        removed_signers: Array<felt252>
    ) {}

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                     Constructor                                            //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // TODO: add constructor arguments to validate deploy
    #[constructor]
    fn constructor(threshold: usize, signers: Array<felt252>) {
        let signers_len = signers.len();
        assert_valid_threshold_and_signers_count(threshold, signers_len);

        // initialize the account
        MultisigStorage::add_signers(signers.span(), 0);

        MultisigStorage::set_threshold(threshold);

        let removed_signers = ArrayTrait::new();

        ConfigurationUpdated(threshold, signers_len, signers, removed_signers);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                     External functions                                     //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // TODO use the actual signature of the account interface
    #[external]
    fn __validate__(ref calls: Array<Call>) -> felt252 {
        let account_address = get_contract_address();

        if calls.len() == 1_usize {
            let call = calls.at(0_usize);
            if (*call.to).into() == account_address.into() {
                let selector = *call.selector;
                assert(selector != EXECUTE_AFTER_UPGRADE_SELECTOR, 'argent/forbidden-call');
            }
        } else {
            // make sure no call is to the account
            assert_no_self_call(calls.span(), account_address);
        }

        assert_is_valid_tx_signature();

        VALIDATED
    }

    #[external]
    fn __validate_declare__(class_hash: felt252) -> felt252 {
        assert_is_valid_tx_signature();
        VALIDATED
    }

    #[raw_input]
    #[external]
    fn __validate_deploy__(
        class_hash: felt252,
        contract_address_salt: felt252,
        threshold: usize,
        signers: Array<felt252>
    ) -> felt252 {
        let tx_info = starknet::get_tx_info().unbox();
        let signature_array = spans::span_to_array(tx_info.signature);

        assert(signature_array.len() == SignerSignatureSize, 'argent/invalid-signature-length');

        let mut signer_signatures_out = ArrayTrait::<SignerSignature>::new();
        let hash = tx_info.transaction_hash;
        // hardcoded to 1 as only one signature is needed
        let parsed_signatures = deserialize_array_signer_signature(
            signature_array, signer_signatures_out, 1_usize
        ).unwrap();
        let valid = is_valid_signatures_array(hash, parsed_signatures.span());
        assert(valid, 'argent/invalid-signature');
        VALIDATED
    }

    #[external]
    fn change_threshold(new_threshold: usize) {
        assert_only_self();

        let signers_len = MultisigStorage::get_signers_len();

        assert_valid_threshold_and_signers_count(new_threshold, signers_len);
        MultisigStorage::set_threshold(new_threshold);

        let added_signers = ArrayTrait::new();
        let removed_signers = ArrayTrait::new();

        ConfigurationUpdated(new_threshold, signers_len, added_signers, removed_signers);
    }

    // @dev Adds new signers to the account, additionally sets a new threshold
    // @param new_threshold New threshold
    // @param signers_to_add Contains the new signers, it will revert if it contains any existing signer
    #[external]
    fn add_signers(new_threshold: usize, signers_to_add: Array<felt252>) {
        assert_only_self();
        let (signers_len, last_signer) = MultisigStorage::load();

        let new_signers_len = signers_len + signers_to_add.len();
        assert_valid_threshold_and_signers_count(new_threshold, new_signers_len);

        MultisigStorage::add_signers(signers_to_add.span(), last_signer);
        MultisigStorage::set_threshold(new_threshold);

        let removed_signers = ArrayTrait::new();

        ConfigurationUpdated(new_threshold, new_signers_len, signers_to_add, removed_signers);
    }

    // @dev Removes account signers, additionally sets a new threshold
    // @param new_threshold New threshold
    // @param signers_to_remove Should contain only current signers, otherwise it will revert
    #[external]
    fn remove_signers(new_threshold: usize, signers_to_remove: Array<felt252>) {
        assert_only_self();
        let (signers_len, last_signer) = MultisigStorage::load();

        let new_signers_len = signers_len - signers_to_remove.len();
        assert_valid_threshold_and_signers_count(new_threshold, new_signers_len);

        MultisigStorage::remove_signers(signers_to_remove.span(), last_signer);
        MultisigStorage::set_threshold(new_threshold);

        let added_signers = ArrayTrait::new();

        ConfigurationUpdated(new_threshold, new_signers_len, added_signers, signers_to_remove);
    }

    // @dev Replace one signer with a different one
    // @param signer_to_remove Signer to remove
    // @param signer_to_add Signer to add
    #[external]
    fn replace_signer(signer_to_remove: felt252, signer_to_add: felt252) {
        assert_only_self();
        let (signers_len, last_signer) = MultisigStorage::load();

        MultisigStorage::replace_signer(signer_to_remove, signer_to_add, last_signer);

        let mut added_signers = ArrayTrait::new();
        added_signers.append(signer_to_add);

        let mut removed_signer = ArrayTrait::new();
        removed_signer.append(signer_to_remove);

        ConfigurationUpdated(
            MultisigStorage::get_threshold(), signers_len, added_signers, removed_signer
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                       View functions                                       //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[view]
    fn get_name() -> felt252 {
        NAME
    }

    #[view]
    fn get_version() -> Version {
        // TODO Is this the correct version?
        Version { major: 0_u8, minor: 1_u8, patch: 0_u8 }
    }

    #[view]
    fn get_threshold() -> usize {
        MultisigStorage::get_threshold()
    }

    #[view]
    fn get_signers() -> Array<felt252> {
        MultisigStorage::get_signers()
    }

    #[view]
    fn is_signer(signer: felt252) -> bool {
        MultisigStorage::is_signer(signer)
    }

    // ERC165
    #[view]
    fn supports_interface(interface_id: felt252) -> bool {
        interface_id == ERC165_IERC165_INTERFACE_ID | interface_id == ERC165_ACCOUNT_INTERFACE_ID | interface_id == ERC165_OLD_ACCOUNT_INTERFACE_ID
    }

    #[view]
    fn assert_valid_signer_signature(
        hash: felt252, signer: felt252, signature_r: felt252, signature_s: felt252
    ) {
        let is_valid = is_valid_signer_signature(hash, signer, signature_r, signature_s);
        assert(is_valid, 'argent/invalid-signature');
    }

    #[view]
    fn is_valid_signer_signature(
        hash: felt252, signer: felt252, signature_r: felt252, signature_s: felt252
    ) -> bool {
        let is_signer = MultisigStorage::is_signer(signer);
        assert(is_signer, 'argent/not-a-signer');
        check_ecdsa_signature(hash, signer, signature_r, signature_s)
    }

    #[view]
    fn is_valid_signature(hash: felt252, signatures: Array<felt252>) -> bool {
        let threshold = MultisigStorage::get_threshold();
        assert(threshold != 0_usize, 'argent/uninitialized');
        assert(
            signatures.len() == threshold * SignerSignatureSize, 'argent/invalid-signature-length'
        );
        let mut mut_signatures = signatures;
        let mut signer_signatures_out = ArrayTrait::<SignerSignature>::new();
        let parsed_signatures = deserialize_array_signer_signature(
            mut_signatures, signer_signatures_out, threshold
        ).unwrap();
        is_valid_signatures_array(hash, parsed_signatures.span())
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                          Internal                                          //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    fn assert_is_valid_tx_signature() {
        let tx_info = starknet::get_tx_info().unbox();

        // TODO converting to array is probably avoidable
        let signature_array = spans::span_to_array(tx_info.signature);

        let valid = is_valid_signature(tx_info.transaction_hash, signature_array);
        assert(valid, 'argent/invalid-signature');
    }

    fn is_valid_signatures_array(hash: felt252, signatures: Span<SignerSignature>) -> bool {
        is_valid_signatures_array_helper(hash, signatures, 0)
    }

    fn is_valid_signatures_array_helper(
        hash: felt252, mut signatures: Span<SignerSignature>, last_signer: felt252
    ) -> bool {
        check_enough_gas();

        let sig_pop: Option<@SignerSignature> = signatures.pop_front();
        match sig_pop {
            Option::Some(i) => {
                let signer_sig = *i;
                assert(
                    signer_sig.signer.into() > last_signer.into(), 'argent/signatures-not-sorted'
                );
                let valid_signer_signature = is_valid_signer_signature(
                    hash, signer_sig.signer, signer_sig.signature_r, signer_sig.signature_s
                );
                if !valid_signer_signature {
                    return false;
                }
                is_valid_signatures_array_helper(hash, signatures, signer_sig.signer)
            },
            Option::None(_) => {
                true
            }
        }
    }

    fn assert_valid_threshold_and_signers_count(threshold: usize, signers_len: usize) {
        assert(threshold != 0_usize, 'argent/invalid-threshold');
        assert(signers_len != 0_usize, 'argent/invalid-signers-len');
        assert(threshold <= signers_len, 'argent/bad-threshold');
    }
}