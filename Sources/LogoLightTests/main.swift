// Run with: swift run LogoLightTests

import Foundation

// Sent to a file or a pipe, output would otherwise wait in a buffer, and a run that hangs or crashes
// would leave a log that stops in an earlier suite.
setvbuf(stdout, nil, _IOLBF, 0)

let harness = TestHarness()
statusReaderTests(harness)
macFinishTests(harness)
panelStateTests(harness)
controlLinkTests(harness)
commandTests(harness)
passwordlessRuleTests(harness)
await controllerTests(harness)
await directControlTests(harness)
await effectTests(harness)
await brightnessTests(harness)
await fadeTests(harness)
await stoppingTests(harness)
await landingTests(harness)
await switchingTests(harness)
await launchTests(harness)
await batteryTests(harness)
await displayBrightnessTests(harness)
await chargingTests(harness)
await lidTests(harness)
await morseTests(harness)
await soundTests(harness)
await loanTests(harness)
harness.finish()
