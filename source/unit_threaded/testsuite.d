module unit_threaded.testsuite;

import unit_threaded.testcase;
import unit_threaded.io;
import unit_threaded.options;
import std.datetime;
import std.parallelism: taskPool;
import std.algorithm;
import std.conv: text;
import std.array;
import core.runtime;



/**
 * Only exists because taskPool.amap only works with regular functions,
 * not closures.
 */
auto runTest(TestCase test)
{
    return test();
}

/**
 * Responsible for running tests and printing output.
 */
struct TestSuite
{
    this(in Options options, in TestData[] testData)
    {
        _options = options;
        _testData = testData;
        _testCases = createTestCases(testData, options.testsToRun);
        WriterThread.start;
    }

    ~this() {
        WriterThread.get.join;
    }

    /**
     Runs all test cases.
     Returns: true if no test failed, false otherwise.
     */
    bool run()
    {
        if(!_testCases.length)
        {
            utWritelnRed("Error! No tests to run for args: ");
            utWriteln(_options.testsToRun);
            return false;
        }

        immutable elapsed = doRun();

        if(!numTestsRun)
        {
            utWriteln("Did not run any tests!!!");
            return false;
        }

        utWriteln("\nTime taken: ", elapsed);
        utWrite(numTestsRun, " test(s) run, ");
        const failuresStr = text(_failures.length, " failed");
        if(_failures.length)
        {
            utWriteRed(failuresStr);
        }
        else
        {
            utWrite(failuresStr);
        }

        void printAbout(string attr)(in string msg)
        {
            const num = _testData.filter!(a => mixin("a. " ~ attr)).count;
            if(num)
            {
                utWrite(", ");
                utWriteYellow(num, " " ~ msg);
            }
        }

        printAbout!"hidden"("hidden");
        printAbout!"shouldFail"("failing as expected");

        utWriteln(".\n");

        if(_failures.length)
        {
            utWritelnRed("Unit tests failed!\n");
            return false; //oops
        }

        utWritelnGreen("OK!\n");


        return true;
    }

private:

    const(Options) _options;
    const(TestData)[] _testData;
    TestCase[] _testCases;
    string[] _failures;
    StopWatch _stopWatch;

    /**
     * Runs the tests with the given options.
     * Returns: how long it took to run.
     */
    Duration doRun()
    {
        auto tests = getTests();
        _stopWatch.start();

        if(_options.multiThreaded)
        {
            _failures = reduce!((a, b) => a ~ b)(_failures,
                                                 taskPool.amap!runTest(tests));
        }
        else
        {
            foreach(test; tests) _failures ~= test();
        }

        handleFailures();

        _stopWatch.stop();
        return cast(Duration)_stopWatch.peek();
    }


    auto getTests()
    {
        auto tests = _testCases.dup;
        if(_options.random)
        {
            import std.random;
            auto generator = Random(_options.seed);
            tests.randomShuffle(generator);
            utWriteln("Running tests in random order. ",
                      "To repeat this run, use --seed ", _options.seed);
        }
        return tests;
    }

    void handleFailures()
    {
        if(_failures) utWriteln("");
        foreach(failure; _failures)
        {
            utWrite("Test ", failure, " ");
            utWriteRed("failed");
            utWriteln(".");
        }
        if(_failures) utWriteln("");
    }

    @property ulong numTestsRun() const pure
    {
        return _testCases.map!(a => a.numTestsRun).reduce!((a, b) => a + b);
    }
}

/**
 * Replace the D runtime's normal unittest block tester with our own
 */
shared static this()
{
    Runtime.moduleUnitTester = &moduleUnitTester;
}

/**
 * Replacement for the usual unittest runner. This is needed so that the
 * unittest blocks for unit_threaded itself run as usual, but the other
 * tests are not run since unit_threaded runs those.
 */
private bool moduleUnitTester()
{
    foreach(module_; ModuleInfo) {
        if(module_ && module_.unitTest &&
           module_.name.startsWith("unit_threaded.")) {
                module_.unitTest()();
        }
    }

    return true;
}


/**
 * Creates tests cases from the given modules.
 * If testsToRun is empty, it means run all tests.
 */
private TestCase[] createTestCases(in TestData[] testData, in string[] testsToRun = [])
{
    bool[TestCase] tests;

    foreach(const data; testData)
    {
        if(!isWantedTest(data, testsToRun)) continue;
        tests[createTestCase(data)] = true;
    }

    return tests.keys.sort!((a, b) => a.name < b.name).array;
}


private TestCase createTestCase(in TestData testData)
{
    auto testCase = new FunctionTestCase(testData);

    if(testData.singleThreaded)
    {
        // @SingleThreaded tests in the same module run sequentially.
        // A CompositeTestCase is created for each module with at least
        // one @SingleThreaded test and subsequent @SingleThreaded tests
        // appended to it
        static CompositeTestCase[string] composites;

        const moduleName = testData.name.splitter(".").
            array[0 .. $ - 1].
            reduce!((a, b) => a ~ "." ~ b);

        if(moduleName !in composites)
            composites[moduleName] = new CompositeTestCase;

        composites[moduleName] ~= testCase;
        return composites[moduleName];
    }

    if(testData.shouldFail)
    {
        return new ShouldFailTestCase(testCase);
    }

    return testCase;
}


private bool isWantedTest(in TestData testData, in string[] testsToRun)
{
    //hidden tests are not run by default, every other one is
    if(!testsToRun.length) return !testData.hidden;
    bool matchesExactly(in string t)
    {
        return t == testData.name;
    }
    bool matchesPackage(in string t) //runs all tests in package if it matches
    {
        with(testData) return !hidden && name.length > t.length &&
                       name.startsWith(t) && name[t.length .. $].canFind(".");
    }

    return testsToRun.any!(t => matchesExactly(t) || matchesPackage(t));
}


unittest
{
    //existing, wanted
    assert(isWantedTest(TestData("tests.server.testSubscribe"),
                        ["tests"]));
    assert(isWantedTest(TestData("tests.server.testSubscribe"),
                        ["tests."]));
    assert(isWantedTest(TestData("tests.server.testSubscribe"),
                        ["tests.server.testSubscribe"]));
    assert(!isWantedTest(TestData("tests.server.testSubscribe"),
                         ["tests.server.testSubscribeWithMessage"]));
    assert(!isWantedTest(TestData("tests.stream.testMqttInTwoPackets"),
                         ["tests.server"]));
    assert(isWantedTest(TestData("tests.server.testSubscribe"),
                        ["tests.server"]));
    assert(isWantedTest(TestData("pass_tests.testEqual"),
                        ["pass_tests"]));
    assert(isWantedTest(TestData("pass_tests.testEqual"),
                        ["pass_tests.testEqual"]));
    assert(isWantedTest(TestData("pass_tests.testEqual"),
                        []));
    assert(!isWantedTest(TestData("pass_tests.testEqual"),
                         ["pass_tests.foo"]));
    assert(!isWantedTest(TestData("example.tests.pass.normal.unittest"),
                         ["example.tests.pass.io.TestFoo"]));
    assert(isWantedTest(TestData("example.tests.pass.normal.unittest"),
                        []));
    assert(!isWantedTest(TestData("tests.pass.attributes.testHidden",
                                  null /*func*/, true /*hidden*/),
                         ["tests.pass"]));
}
