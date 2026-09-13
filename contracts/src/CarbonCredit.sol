// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Pausable} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Pausable.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RetirementRegistry} from "./RetirementRegistry.sol";

/// @title CarbonCredit
/// @notice ERC-1155 carbon credits. Token id == `projectId`. Retirement burns supply forever.
/// @dev Interface locked by `docs/CONTRACT.md` §7. Dataplane reconciles `CreditsMinted` /
///      `CreditsRetired`. Double-spend is prevented by burning; the registry is append-only.
contract CarbonCredit is ERC1155, ERC1155Supply, ERC1155Pausable, AccessControl, ReentrancyGuard {
    /// @notice Role allowed to mint verified credit batches.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role allowed to pause and unpause transfers / mint / retire.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Append-only retirement ledger. Immutable after construction.
    RetirementRegistry public immutable registry;

    /// @dev 各專案累計退役量。只在 retire() 增加，沒有反向操作。
    mapping(uint256 projectId => uint256 amount) private _retired;

    /// @notice A verified batch of credits was minted. Dataplane uses this for reconciliation.
    event CreditsMinted(uint256 indexed projectId, address indexed to, uint256 amount, bytes32 verificationHash);

    /// @notice Credits were burned and recorded as retired. Dataplane uses this for reconciliation.
    event CreditsRetired(uint256 indexed projectId, address indexed by, uint256 amount, string beneficiary);

    /// @notice `amount` must be greater than zero.
    error InvalidAmount();

    /// @notice `to` / `admin` / `registry_` must not be the zero address.
    error InvalidAddress();

    /// @notice `beneficiary` must be a non-empty UTF-8 string.
    error InvalidBeneficiary();

    /// @param admin Receives `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, and `PAUSER_ROLE`.
    /// @param registry_ Already-deployed `RetirementRegistry` (admin must later grant `RECORDER_ROLE`).
    /// @param uri_ ERC-1155 metadata URI; clients substitute `{id}`.
    constructor(address admin, address registry_, string memory uri_) ERC1155(uri_) {
        if (admin == address(0) || registry_ == address(0)) {
            revert InvalidAddress();
        }
        registry = RetirementRegistry(registry_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /// @notice Mint `amount` credits of `projectId` to `to` after off-chain verification.
    /// @param to Recipient of the newly minted credits.
    /// @param projectId Carbon project identifier (ERC-1155 token id).
    /// @param amount Units to mint (must be > 0).
    /// @param verificationHash Commitment to the off-chain verification evidence.
    function mintBatch(address to, uint256 projectId, uint256 amount, bytes32 verificationHash)
        external
        nonReentrant
        onlyRole(MINTER_ROLE)
    {
        if (to == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        // 先記事件再鑄幣：若 _mint 的接收回呼失敗，整筆交易回滾，不會留下幽靈事件。
        emit CreditsMinted(projectId, to, amount, verificationHash);
        _mint(to, projectId, amount, "");
    }

    /// @notice Burn `amount` of the caller's credits and record an irreversible retirement.
    /// @dev Burning is the anti-double-spend primitive: retired units leave circulating supply
    ///      and cannot be transferred or retired again. The registry appends an audit certificate.
    /// @param projectId Carbon project identifier (ERC-1155 token id).
    /// @param amount Units to retire (must be > 0 and <= caller balance).
    /// @param beneficiary Non-empty beneficiary recorded on the retirement certificate.
    function retire(uint256 projectId, uint256 amount, string calldata beneficiary) external nonReentrant {
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (bytes(beneficiary).length == 0) {
            revert InvalidBeneficiary();
        }

        address by = _msgSender();

        // 事件與狀態先寫，再銷毀、再寫登記冊，避免 lint 視為事件落在外部呼叫之後。
        emit CreditsRetired(projectId, by, amount, beneficiary);
        _retired[projectId] += amount;
        _burn(by, projectId, amount);
        // ReentrancyGuard 擋住登記冊回呼再入；_burn 失敗會整筆回滾。
        registry.recordRetirement(projectId, by, amount, beneficiary);
    }

    /// @notice Cumulative retired (burned) amount for `projectId`. Never decreases.
    function totalRetired(uint256 projectId) external view returns (uint256) {
        return _retired[projectId];
    }

    /// @notice Pause minting, retirement, and transfers. Emergency switch.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume minting, retirement, and transfers.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @inheritdoc ERC1155
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @dev 合併 ERC1155Supply（流通量）與 ERC1155Pausable（緊急凍結）的 `_update`。
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply, ERC1155Pausable)
    {
        super._update(from, to, ids, values);
    }
}
