//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../libraries/DataTypes.sol";
import "./IFeeModel.sol";

// INTERFACE: View functions for the contract.

interface IContangoView {
    function closingOnly() external view returns (bool);
    function feeModel(Symbol symbol) external view returns (IFeeModel);
    function position(PositionId positionId) external view returns (Position memory _position);
}
