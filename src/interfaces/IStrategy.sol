// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IStrategy
 * @notice Interfaz estandar que todas las strategies deben implementar
 * @dev Permite que StrategyManager trate a Aave, Compound, etc. de forma uniforme
 */
interface IStrategy {
    //* Eventos

    /**
     * @notice Emitido cuando se depositan assets en el protocolo
     * @param caller Direccion que ejecuto el deposit
     * @param assets Cantidad de WETH depositados
     * @param shares Shares recibidos del protocolo (puede diferir de assets)
     */
    event Deposited(address indexed caller, uint256 assets, uint256 shares);

    /**
     * @notice Emitido cuando se retiran assets del protocolo
     * @param caller Direccion que ejecuto el withdraw
     * @param assets Cantidad de WETH retirados
     * @param shares Shares quemados del protocolo
     */
    event Withdrawn(address indexed caller, uint256 assets, uint256 shares);

    //* Funciones principales

    /**
     * @notice Deposita WETH en el protocolo subyacente
     * @dev El caller debe transferir WETH a esta strategy antes de llamar
     * @param assets Cantidad de WETH a depositar
     * @return shares Shares recibidos (puede ser diferente de assets)
     */
    function deposit(uint256 assets) external returns (uint256 shares);

    /**
     * @notice Retira WETH del protocolo subyacente
     * @dev Transfiere WETH al caller despues de retirar del protocolo
     * @param assets Cantidad de WETH a retirar
     * @return actualWithdrawn WETH realmente retirado (incluye yield)
     */
    function withdraw(uint256 assets) external returns (uint256 actualWithdrawn);

    //* Funciones de consulta

    /**
     * @notice Retorna el valor total de assets bajo gestion
     * @dev Incluye WETH depositado + yield acumulado
     * @dev Como el WETH estará depositado en el protocolo X, se calculará
     *      usando los shares (x-token) recibidos del protocolo subyacente
     * @return total Valor total en WETH (wei)
     */
    function totalAssets() external view returns (uint256 total);

    /**
     * @notice Retorna el APY actual del protocolo
     * @dev En basis points: 100 = 1%, 350 = 3.5%, 1000 = 10%
     * @return apyBasisPoints APY en basis points
     */
    function apy() external view returns (uint256 apyBasisPoints);

    /**
     * @notice Retorna el nombre de la strategy
     * @return strategyName Ej: "Aave v3 WETH Strategy"
     */
    function name() external view returns (string memory strategyName);

    /**
     * @notice Retorna la direccion del asset que maneja (actualmente solo WETH)
     * @return assetAddress Direccion del token (WETH en nuestro caso)
     */
    function asset() external view returns (address assetAddress);
}
