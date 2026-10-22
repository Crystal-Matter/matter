# Concentration measurement servers

Matter 1.6 defines ten derived concentration measurement clusters at revision 5.
Crystal Matter provides the CO, CO₂, NO₂, ozone, PM2.5, formaldehyde, PM1, PM10,
TVOC, and radon clusters through a shared declaration. Each class has its own
standard cluster ID and the same constructor and update methods as the existing
`CarbonDioxideConcentrationMeasurement` class.

At construction, supply at least one of `measurement_unit` (numeric measurement)
or `level_value` (level indication). Numeric readings and fixed minimum/maximum
values may be `nil` when a sensor cannot provide them. A peak or average window
enables that feature and requires numeric measurement; its value may initially
be `nil`. Windows must be at most 604,800 seconds. Updates reject nonfinite or
out-of-range readings and leave the previous value intact.

Level indication advertises MediumLevel and CriticalLevel so applications can
use all five `LevelValue` enum values. Numeric measurement advertises only the
features configured by its supplied window values. The measurement medium is
always present and fixed. Minimum, maximum, uncertainty, and unit also have
fixed quality when present.

The humidity sensor example includes a second, conforming Air Quality Sensor
endpoint with CO₂ numeric and CO level readings. Its [E2E specification](../e2e/spec/humidity_sensor_spec.cr)
reads those attributes with the official `chip-tool` controller.
