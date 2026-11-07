// Run with: swift run LogoLightTests

let harness = TestHarness()
statusReaderTests(harness)
commandTests(harness)
passwordlessRuleTests(harness)
await controllerTests(harness)
await directControlTests(harness)
await effectTests(harness)
harness.finish()
