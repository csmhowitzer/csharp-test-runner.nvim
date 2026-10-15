namespace Sample.MSTest;

[TestClass]
public class CalcTests
{
    [TestMethod]
    public void Adds() => Assert.AreEqual(4, 2 + 2);

    [TestMethod]
    public void FailsEqual()
    {
        Assert.AreEqual(5, 2 + 2);
    }

    [TestMethod]
    public async Task AsyncThrows()
    {
        await Task.Yield();
        throw new InvalidOperationException("boom it's broken");
    }

    [TestMethod]
    [DataRow(1, true)]
    [DataRow(2, false)]
    public void RowsMixed(int n, bool expected)
    {
        Console.WriteLine($"checking {n}");
        Assert.AreEqual(expected, n == 1 || n == 2);
    }

    [TestMethod, Ignore("not yet")]
    public void Skipped() { }
}
