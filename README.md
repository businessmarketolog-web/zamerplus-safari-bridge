# ZamerPlus Safari Bridge

Safari remains the main interface. This small iOS helper supplies the two hardware APIs Safari does not expose directly:

- Apple RoomPlan / LiDAR
- CoreBluetooth for Bosch GLM

The helper is launched from Safari by the custom scheme `zamerplusbridge://` and returns data to the HTTPS site through the URL fragment.

The GitHub Actions workflow builds an **unsigned IPA**. It must be re-signed by SideStore/AltStore or another legitimate personal signing method before installation.

Bosch packet parsing is based on reverse-engineered GLM-family BLE behavior and must be verified against the exact GLM 50-27 C firmware.
