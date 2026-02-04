// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IComet} from "../interfaces/IComet.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title CompoundStrategy
 * @author cristianrisueo
 * @notice Estrategia que deposita WETH en Compound v3 para generar yield
 * @dev Implementa IStrategy para integracion con StrategyManager
 */
contract CompoundStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando el depósito en Compound falla
     */
    error CompoundStrategy__DepositFailed();

    /**
     * @notice Error cuando el retiro de Compound falla
     */
    error CompoundStrategy__WithdrawFailed();

    /**
     * @notice Error cuando solo el manager puede llamar
     */
    error CompoundStrategy__OnlyManager();

    //* Variables de estado

    /// @notice Direccion del StrategyManager autorizado
    address public immutable manager;

    /// @notice Instancia del Comet de Compound v3
    IComet private immutable compound_comet;

    /// @notice Direccion del asset subyacente (WETH)
    address private immutable weth_address;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert CompoundStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor de CompoundStrategy
     * @dev Inicializa la strategy con Compound v3 y aprueba el comet
     * @param _manager Direccion del StrategyManager
     * @param _weth Direccion del token WETH
     * @param _compound_comet Direccion del Comet de Compound v3
     */
    constructor(address _manager, address _weth, address _compound_comet) {
        // Asigna las direcciones de StrategyManager y WETH. Inicializa comet de Compound
        manager = _manager;
        weth_address = _weth;
        compound_comet = IComet(_compound_comet);

        // Aprueba Compound Comet para mover todo WETH de esta strategy
        IERC20(_weth).forceApprove(_compound_comet, type(uint256).max);
    }

    //* Implementacion de IStrategy

    /**
     * @notice Deposita WETH en Compound v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Asume que el WETH ya fue transferido a esta strategy desde StrategyManager
     * @param assets Cantidad de WETH a depositar en Compound
     * @return shares Devuelve cantidad depositada (Compound no usa tokens tipo cToken en v3)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Realiza el depósito en Compound y emite evento. En caso de error revierte
        try compound_comet.supply(weth_address, assets) {
            shares = assets;
            emit Deposited(msg.sender, assets, shares);
        } catch {
            revert CompoundStrategy__DepositFailed();
        }
    }

    /**
     * @notice Retira WETH de Compound v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Transfiere el WETH retirado directamente al manager
     * @param assets Cantidad de WETH a retirar de Compound
     * @return actualWithdrawn WETH realmente retirado (incluye yield)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actualWithdrawn) {
        // Realiza withdraw de Compound (recibe WETH + yield). Transfiere a StrategyManager
        // y emite evento, en caso de error revierte
        try compound_comet.withdraw(weth_address, assets) {
            actualWithdrawn = assets;
            IERC20(weth_address).safeTransfer(msg.sender, actualWithdrawn);
            emit Withdrawn(msg.sender, actualWithdrawn, assets);
        } catch {
            revert CompoundStrategy__WithdrawFailed();
        }
    }

    /**
     * @notice Devuelve el total de assets bajo gestion en Compound
     * @dev Compound v3 usa accounting interno, consulta balance del usuario en el Comet
     *      por lo que no hay que hacer cálculos extra
     * @return total Cantidad de WETH depositado + yield acumulado
     */
    function totalAssets() external view returns (uint256 total) {
        return compound_comet.balanceOf(address(this));
    }

    /**
     * @notice Devuelve el APY actual de Compound para WETH
     * @dev Calcula APY desde el supply rate que devuelve Compound
     * @dev Supply rate esta en por segundo (1e18 base), convertimos a basis points anuales
     * @return apyBasisPoints APY en basis points (350 = 3.5%)
     */
    function apy() external view returns (uint256 apyBasisPoints) {
        // Obtiene utilizacion actual del pool
        uint256 utilization = compound_comet.getUtilization();

        // Obtiene supply rate basado en utilizacion (Compound V3 devuelve uint64)
        uint64 supply_rate_per_second = compound_comet.getSupplyRate(utilization);

        // Convierte rate por segundo a APY anual en basis points
        // Cast a uint256 para evitar overflow en multiplicacion
        // supply_rate * seconds_per_year / 1e18 * 10000 = basis points
        // Simplificado: (rate * 31536000 * 10000) / 1e18
        apyBasisPoints = (uint256(supply_rate_per_second) * 315360000000) / 1e18;
    }

    /**
     * @notice Devuelve el nombre de la strategy
     * @return strategyName Nombre descriptivo de la strategy
     */
    function name() external pure returns (string memory strategyName) {
        return "Compound v3 WETH Strategy";
    }

    /**
     * @notice Devuelve la direccion del asset
     * @return assetAddress Direccion de WETH
     */
    function asset() external view returns (address assetAddress) {
        return weth_address;
    }

    //* Funciones de utilidad

    /**
     * @notice Devuelve el supply rate actual de Compound
     * @dev Util para debugging y verificacion de APY
     * @return rate Supply rate por segundo (base 1e18) convertido a uint256
     */
    function getSupplyRate() external view returns (uint256 rate) {
        return uint256(compound_comet.getSupplyRate(compound_comet.getUtilization()));
    }

    /**
     * @notice Devuelve la utilizacion actual del pool de Compound
     * @dev Utilization = borrowed / supplied
     * @return utilization Porcentaje de utilizacion (base 1e18, ej: 0.5e18 = 50%)
     */
    function getUtilization() external view returns (uint256 utilization) {
        return compound_comet.getUtilization();
    }
}
