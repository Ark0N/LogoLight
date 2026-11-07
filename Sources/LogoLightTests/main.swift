// Run with: swift run LogoLightTests

let harness = TestHarness()
statusReaderTests(harness)
macFinishTests(harness)
commandTests(harness)
passwordlessRuleTests(harness)
await controllerTests(harness)
await directControlTests(harness)
await effectTests(harness)
await brightnessTests(harness)
await switchingTests(harness)
await launchTests(harness)
harness.finish()
