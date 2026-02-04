// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IComet
 * @notice Interfaz de Comet Compound v3
 * @dev Interfaz simplificada con solo las funciones necesarias para CompoundStrategy
 * @dev A diferencia de Aave, no importamos las librerías oficiales porque:
 *      1. Las librerías oficiales están sucias (dependencias indexadas, etc)
 *      2. Solo necesitamos 5 funciones de mierda
 *      Yo personalmente adoro la consistencia, pensé en tener todo cómo interfaces o
 *      como librerías, pero no mezclado, pero por eficacia, en este caso no compensa
 *      Lo que necesitamos de Aave es más complejo y las librerías están limpias
 */
interface IComet {
    /**
     * @notice Deposita assets en Compound v3
     * @param asset Direccion del token a depositar
     * @param amount Cantidad a depositar
     */
    function supply(address asset, uint256 amount) external;

    /**
     * @notice Retira assets de Compound v3
     * @param asset Direccion del token a retirar
     * @param amount Cantidad a retirar
     */
    function withdraw(address asset, uint256 amount) external;

    /**
     * @notice Devuelve el balance de un usuario en Compound
     * @param account Direccion del usuario
     * @return balance Balance del usuario (incluye yield)
     */
    function balanceOf(address account) external view returns (uint256 balance);

    /**
     * @notice Devuelve el supply rate actual del pool
     * @dev Compound V3 devuelve uint64 representando rate por segundo (base 1e18)
     * @param utilization Utilizacion actual del pool
     * @return rate Supply rate por segundo (base 1e18)
     */
    function getSupplyRate(uint256 utilization) external view returns (uint64 rate);

    /**
     * @notice Devuelve la utilizacion actual del pool
     * @dev Utilization = total borrowed / total supplied
     * @return utilization Porcentaje de utilizacion (base 1e18)
     */
    function getUtilization() external view returns (uint256 utilization);
}
