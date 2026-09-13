// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RetirementRegistry
/// @notice Append-only ledger of carbon-credit retirements. Records cannot be updated or deleted.
/// @dev Only `RECORDER_ROLE` (the `CarbonCredit` contract) may append. This is the audit trail
///      that dataplane / off-chain reconcilers read alongside `CreditsRetired` events.
contract RetirementRegistry is AccessControl, ReentrancyGuard {
    /// @notice Role allowed to append retirement records. Granted to `CarbonCredit` at deploy.
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    /// @notice Single immutable retirement certificate.
    struct Retirement {
        uint256 projectId;
        address account;
        uint256 amount;
        string beneficiary;
        uint256 timestamp;
    }

    /// @dev 退役紀錄只能附加，沒有更新或刪除路徑（退役不可逆）。
    Retirement[] private _records;

    /// @dev 各專案累計退役量，與 CarbonCredit.totalRetired 對帳。
    mapping(uint256 projectId => uint256 amount) private _retired;

    /// @notice Emitted when a retirement is appended. Indexed fields match the CarbonCredit event.
    event RetirementRecorded(
        uint256 indexed id, uint256 indexed projectId, address indexed account, uint256 amount, string beneficiary
    );

    /// @notice `amount` must be greater than zero.
    error InvalidAmount();

    /// @notice `account` must not be the zero address.
    error InvalidAccount();

    /// @notice `beneficiary` must be a non-empty UTF-8 string.
    error InvalidBeneficiary();

    /// @notice `admin` must not be the zero address.
    error InvalidAdmin();

    /// @param admin Account that receives `DEFAULT_ADMIN_ROLE` (can grant `RECORDER_ROLE`).
    constructor(address admin) {
        if (admin == address(0)) {
            revert InvalidAdmin();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Append a retirement record. Irreversible; the same tokens cannot be recorded twice
    ///         because the caller (`CarbonCredit`) burns them first.
    /// @param projectId ERC-1155 token id / carbon project identifier.
    /// @param account Holder who retired the credits.
    /// @param amount Tonnes (or project units) retired.
    /// @param beneficiary Human-readable beneficiary recorded on the certificate.
    function recordRetirement(uint256 projectId, address account, uint256 amount, string calldata beneficiary)
        external
        nonReentrant
        onlyRole(RECORDER_ROLE)
    {
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (account == address(0)) {
            revert InvalidAccount();
        }
        if (bytes(beneficiary).length == 0) {
            revert InvalidBeneficiary();
        }

        // 先寫狀態再對外可觀測：即使之後加 hook 也不會雙記。
        _retired[projectId] += amount;
        uint256 id = _records.length;
        _records.push(
            Retirement({
                projectId: projectId,
                account: account,
                amount: amount,
                beneficiary: beneficiary,
                timestamp: block.timestamp
            })
        );

        emit RetirementRecorded(id, projectId, account, amount, beneficiary);
    }

    /// @notice Cumulative retired amount for `projectId`. Monotonically increasing.
    function totalRetired(uint256 projectId) external view returns (uint256) {
        return _retired[projectId];
    }

    /// @notice Number of append-only records (next id == count).
    function retirementCount() external view returns (uint256) {
        return _records.length;
    }

    /// @notice Read a single certificate by its append-only id.
    function getRetirement(uint256 id)
        external
        view
        returns (uint256 projectId, address account, uint256 amount, string memory beneficiary, uint256 timestamp)
    {
        Retirement storage rec = _records[id];
        return (rec.projectId, rec.account, rec.amount, rec.beneficiary, rec.timestamp);
    }
}
