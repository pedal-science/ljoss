import Foundation

print("model tests")
print("")
testReordering()
testParallels()
testRejectedEdits()
testRenderSlotMapping()
testCodableRoundTrip()
testLayoutIsNonDestructive()
testFlowWrapping()
testFlowWire()
testFlowHitTesting()
print("")
if failures == 0 {
    print("PASS")
    exit(0)
} else {
    print("\(failures) FAILURE\(failures == 1 ? "" : "S")")
    exit(1)
}
