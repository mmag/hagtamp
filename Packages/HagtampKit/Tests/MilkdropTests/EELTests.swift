import Testing

@testable import Milkdrop

@Suite struct EELTests {
    func run(_ code: String, _ setup: [String: Double] = [:]) throws -> EELVariables {
        let vars = EELVariables()
        for (name, value) in setup { vars[name] = value }
        try EELProgram(code, variables: vars).run(vars)
        return vars
    }

    @Test func arithmeticAndPrecedence() throws {
        let v = try run("a = 1 + 2 * 3; b = (1 + 2) * 3; c = -2 ^ 2; d = 2 ^ 3 ^ 2; e = 7 % 3; f = 1 / 0; g = 10 - 4 - 3")
        #expect(v["a"] == 7 && v["b"] == 9 && v["e"] == 1 && v["f"] == 0 && v["g"] == 3)
        #expect(v["c"] == -4)  // unary minus binds looser than ^
        #expect(v["d"] == 512)  // ^ is right-associative
    }

    @Test func assignmentsAndCase() throws {
        let v = try run("Zoom = 1; zoom += 0.5; ZOOM *= 2; x -= 1; y = x; q1 /= 0; n = 17; n %= 5", ["x": 3])
        #expect(v["zoom"] == 3 && v["x"] == 2 && v["y"] == 2 && v["q1"] == 0 && v["n"] == 2)
    }

    @Test func comparisonsLogicAndConditions() throws {
        let v = try run("""
            a = above(3, 2) + below(3, 2) * 10 + equal(0.1 + 0.2, 0.3) * 100;
            b = if(a > 50, 1, 2); c = a == 101 ? 5 : 6; d = !0 && (1 || 0); e = band(1, 0) + bor(0, 2);
            f = 3 < 2 ? 7 : 3 >= 3 ? 8 : 9
            """)
        #expect(v["a"] == 101 && v["b"] == 1 && v["c"] == 5 && v["d"] == 1 && v["e"] == 1 && v["f"] == 8)
    }

    @Test func functions() throws {
        let v = try run("a = sqr(3) + sqrt(16) + abs(-2) + min(1, 2) + max(1, 2); b = int(2.7) + sign(-3); c = sigmoid(0, 1); d = pow(2, 10); e = atan2(1, 1)")
        #expect(v["a"] == 18 && v["b"] == 1 && v["c"] == 0.5 && v["d"] == 1024)
        #expect(abs(v["e"] - .pi / 4) < 1e-12)
    }

    @Test func sequencesMemoryAndLoops() throws {
        let v = try run("""
            // comments are ignored
            i = 0; loop(5, megabuf(i) = i * i; i += 1); /* block
            comment */ s = megabuf(4) + megabuf(99);
            k = 0; while(k += 1; k < 10); t = (1; 2; 3);
            gmegabuf(3) += 2; g = gmegabuf(3); r = exec2(u = 4, u * 2)
            """)
        #expect(v["s"] == 16 && v["k"] == 10 && v["t"] == 3 && v["g"] == 2 && v["r"] == 8)
    }

    @Test func blocksShareGlobalMemoryOnly() throws {
        let global = EELGlobalMemory()
        let a = EELVariables(global: global), b = EELVariables(global: global)
        try EELProgram("gmegabuf(0) = 42; x = 1", variables: a).run(a)
        try EELProgram("y = gmegabuf(0) + x", variables: b).run(b)
        #expect(b["y"] == 42)
    }

    @Test func emptyAndBrokenCode() throws {
        #expect(try EELProgram(" ;; // nothing\n", variables: EELVariables()).isEmpty)
        #expect(throws: EELError.self) { try EELProgram("a = (1 + ", variables: EELVariables()) }
        #expect(throws: EELError.self) { try EELProgram("3 = a", variables: EELVariables()) }
    }
}
