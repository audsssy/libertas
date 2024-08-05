// ᗪᗩGOᑎ 𒀭 𒀭 𒀭 𒀭 𒀭 𒀭 𒀭 𒀭 𒀭 𒀭 𒀭
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

/// @notice A lite Dagon with delegation for ERC1155/6909 tokens only. Version 1x.
contract Libertas {
    /// ======================= CUSTOM ERRORS ======================= ///

    /// @dev Account is unauthorized to access.
    error Unauthorized();

    /// @dev Inputs are invalid for an ownership setting.
    error InvalidSetting();

    /// @dev Proposal not valid to process.
    error InvalidProposal();

    /// @dev Proposal does not have enough votes to process.
    error InsufficientVotes();

    /// @dev Voter has already voted.
    error AlreadyVoted();

    /// @dev Voter cannot delegate to oneself.
    error InvalidDelegation();

    /// @dev Voter has already delegated.
    error AlreadyDelegated();

    /// =========================== EVENTS =========================== ///

    /// @dev Logs new delegation for an account.
    event DelegateSet(
        address indexed delegator,
        uint256 amount,
        address delegatee
    );

    /// ========================== STRUCTS ========================== ///

    struct Proposal {
        address proposer; // slot 1 @ 160
        uint40 deadline; // slot 1 @ 200
        uint40 threshold; // slot 1 @ 240
        string title;
        string description;
        address target;
        bytes data; // (target != address(0)) ? call target to execute data : solicit structured feedback
    }

    struct Vote {
        address voter; // slot 1 @ 160
        bool pass; // slot 1 @ ?
        uint256 votes;
        bytes data;
    }

    struct Delegation {
        address delegator;
        address delegatee;
        uint256 votes;
    }

    /// ========================== STORAGE ========================== ///

    /// @dev Stores mapping of number of proposals to token/tokenId hashes.
    mapping(bytes32 token => uint256 proposalId) public proposalIds;

    /// @dev Stores mapping of votes to token/tokenId hashes and proposal id.
    mapping(bytes32 token => mapping(uint256 proposalId => Proposal))
        public proposals;

    /// @dev Stores mapping of number of votes to token/tokenId hashes.
    mapping(bytes32 token => uint256 voteId) public voteIds;

    /// @dev Stores mapping of votes to token/tokenId hashes, proposal id, and vote id.
    mapping(bytes32 token => mapping(uint256 proposalId => mapping(uint256 voteId => Vote)))
        public votes;

    /// @dev Stores mapping of vote status to token/tokenId hashes and voter.
    mapping(bytes32 token => mapping(uint256 proposalId => mapping(address voter => bool hasVoted)))
        public voted;

    /// @dev Stores mapping of number of delegations to token/tokenId hashes.
    mapping(bytes32 token => uint256 delegationId) public delegationIds;

    /// @dev Stores mapping of delegations to token/tokenId hashes.
    mapping(bytes32 token => mapping(uint256 delegationId => Delegation))
        public delegations;

    /// @dev Stores mapping of delegation id to token/tokenId hashes and voter.
    mapping(bytes32 token => mapping(address voter => uint256 delegationId))
        public delegationByVoter;

    /// @dev Temporary storage for calculating delegation votes.
    mapping(address delegatee => uint256 votes) public delegatedVotes;

    /// ======================== CONSTRUCTOR ======================== ///

    constructor() payable {}

    /// ===================== VOTING & DELEGATION ===================== ///

    /// @dev Token holders may vote on a proposal for a token/tokenId hash.
    function vote(
        uint256 proposalId,
        address token,
        uint256 tokenId,
        bool pass,
        bytes calldata data
    ) public virtual {
        //  Check user ownership of voting token.
        uint256 balance = _balanceOf(token, msg.sender, tokenId);
        if (balance == 0) revert Unauthorized();

        // Check user delegation status.
        bytes32 _token = keccak256(abi.encodePacked(token, tokenId));
        uint256 id = delegationByVoter[_token][msg.sender];
        if (id == 0) revert InvalidDelegation();

        // Check user vote status.
        if (voted[_token][proposalId][msg.sender]) revert AlreadyVoted();

        // Toggle vote status.
        voted[_token][proposalId][msg.sender] = true;

        unchecked {
            votes[_token][proposalId][++voteIds[_token]] = Vote({
                voter: msg.sender,
                pass: pass,
                votes: balance,
                data: data
            });
        }
    }

    /// @dev Token holder may delegate votes for specified token/tokenId hash.
    function delegate(
        address token,
        uint256 tokenId,
        address delegatee
    ) public {
        //  Check user ownership of voting token.
        uint256 balance = _balanceOf(token, msg.sender, tokenId);
        if (balance == 0) revert Unauthorized();

        bytes32 _token = keccak256(abi.encodePacked(token, tokenId));
        if (delegatee == address(0)) {
            // Check voter delegation id.
            uint256 id = delegationByVoter[_token][msg.sender];
            if (id == 0) revert InvalidDelegation();

            // Reset delegation.
            delete delegations[_token][id];
            delegationByVoter[_token][msg.sender] = 0;
        } else {
            // Check delegation conditions.
            if (msg.sender == delegatee) revert InvalidDelegation();

            // Set delegation.
            delegations[_token][++delegationIds[_token]] = Delegation({
                delegator: msg.sender,
                delegatee: delegatee,
                votes: _balanceOf(token, msg.sender, tokenId)
            });

            // Set delegation id by voter.
            delegationByVoter[_token][msg.sender] = delegationIds[_token];
        }
    }

    /// ======================== GOVERNANCE ======================== ///

    /// @dev Make proposal to a token/tokenId hash.
    function propose(
        address token,
        uint256 tokenId,
        Proposal calldata proposal
    ) public virtual {
        if (_balanceOf(token, msg.sender, tokenId) == 0) revert Unauthorized();
        bytes32 _token = keccak256(abi.encodePacked(token, tokenId));

        unchecked {
            proposals[_token][++proposalIds[_token]] = Proposal({
                proposer: msg.sender,
                deadline: proposal.deadline,
                threshold: proposal.threshold,
                title: proposal.title,
                description: proposal.description,
                target: proposal.target,
                data: proposal.data
            });
        }
    }

    /// @dev Process a proposal.
    function process(
        uint256 proposalId,
        address token,
        uint256 tokenId
    ) public returns (bytes memory result) {
        // Validate processor conditions.
        if (_balanceOf(token, msg.sender, tokenId) == 0) revert Unauthorized();

        // Validate proposal conditions.
        bytes32 _token = keccak256(abi.encodePacked(token, tokenId));
        Proposal memory prop = proposals[_token][proposalId];
        if (proposalId > proposalIds[_token] || proposalId == 0)
            revert InvalidProposal();
        if (prop.deadline > block.timestamp) revert InvalidProposal();

        // Tally votes.
        uint256 forVotes = tallyForVotes(proposalId, _token);

        // Validate process conditions.
        if (prop.threshold > forVotes) revert InsufficientVotes();

        // Process proposal.
        if (prop.target != address(0)) {
            (, result) = prop.target.call(prop.data);
        }
    }

    function tallyForVotes(
        uint256 proposalId,
        bytes32 _token
    ) internal returns (uint256 numOfFor) {
        // Calcuate delegatedVotes.
        Delegation memory _delegation;
        uint256 numOfDelegations = delegationIds[_token];
        for (uint256 i; i < numOfDelegations; ++i) {
            _delegation = delegations[_token][i];

            // If voter has delegated, add vote to temporary delegtee storage.
            delegatedVotes[_delegation.delegatee] += _delegation.votes;
        }

        // Tally by direct and delegated votes.
        Vote memory _vote;
        uint256 numOfVotes = voteIds[_token];
        for (uint256 i; i < numOfVotes; ++i) {
            _vote = votes[_token][proposalId][i];

            if (delegationByVoter[_token][_vote.voter] != 0) {
                // Continue if voter had delegated.
                continue;
            } else {
                // If voter did not delegate, and...

                if (_vote.pass && delegatedVotes[_vote.voter] > 0) {
                    // If voter is a delegator and voted "for", add direct & delegated votes.
                    numOfFor += _vote.votes + delegatedVotes[_vote.voter];
                } else {
                    // If voter is not a delegator, add direct votes.
                    (_vote.pass) ? numOfFor += _vote.votes : numOfFor;
                }
            }
        }
    }

    /// ====================== PUBLIC READ ====================== ///

    function getProposals(
        address token,
        uint256 tokenId
    ) public view returns (Proposal[] memory _proposals) {
        bytes32 _token = keccak256(abi.encodePacked(token, tokenId));
        uint256 numOfProposals = proposalIds[_token];
        _proposals = new Proposal[](numOfProposals);
        for (uint256 i = 1; i <= numOfProposals; ++i) {
            _proposals[i] = proposals[_token][i];
        }
    }

    function getVotes(
        uint256 proposalId,
        address token,
        uint256 tokenId
    ) public view returns (Vote[] memory _votes) {
        bytes32 _token = keccak256(abi.encodePacked(token, tokenId));
        uint256 numOfVotes = voteIds[_token];
        _votes = new Vote[](numOfVotes);
        for (uint256 i = 1; i <= numOfVotes; ++i) {
            _votes[i] = votes[_token][proposalId][i];
        }
    }

    function getDelegations(
        address token,
        uint256 tokenId
    ) public view returns (Delegation[] memory _delegations) {
        bytes32 _token = keccak256(abi.encodePacked(token, tokenId));
        uint256 numOfDelegations = delegationIds[_token];
        _delegations = new Delegation[](numOfDelegations);
        for (uint256 i = 1; i <= numOfDelegations; ++i) {
            _delegations[i] = delegations[_token][i];
        }
    }

    /// =================== EXTERNAL TOKEN HELPERS =================== ///

    /// @dev Returns the amount of ERC1155/6909 `token` `id` owned by `account`.
    function _balanceOf(
        address token,
        address account,
        uint256 id
    ) internal view virtual returns (uint256 amount) {
        assembly ("memory-safe") {
            mstore(0x00, 0x00fdd58e000000000000000000000000) // `balanceOf(address,uint256)`.
            mstore(0x14, account) // Store the `account` argument.
            mstore(0x34, id) // Store the `id` argument.
            pop(staticcall(gas(), token, 0x10, 0x44, 0x20, 0x20))
            amount := mload(0x20)
            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.
        }
    }
}
