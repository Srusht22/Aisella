// The shared conformance kit, run against the fixture-only stub provider.
import { conformanceSuite } from "../conformance.ts";
import { stubFixture } from "./stub_fixture.ts";

conformanceSuite("stub", () => stubFixture());
