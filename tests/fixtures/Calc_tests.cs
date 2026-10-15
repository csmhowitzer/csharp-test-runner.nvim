namespace Sample.XUnit;

public class CalcTests
{
    [Fact]
    public void Adds() => Assert.Equal(4, 2 + 2);

    [Fact]
    public void FailsEqual()
    {
        Assert.Equal(5, 2 + 2);
    }

    [Fact]
    public async Task AsyncThrows()
    {
        await Task.Yield();
        throw new InvalidOperationException("boom it's broken");
    }

    [Theory]
    [InlineData(1, true)]
    [InlineData(2, false)]
    public void TheoryMixed(int n, bool expected)
    {
        Console.WriteLine($"checking {n}");
        Assert.Equal(expected, n == 1 || n == 2);
    }

    [Fact(Skip = "not yet")]
    public void Skipped() { }
}
