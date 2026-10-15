namespace N;
public abstract class Base<T> where T : class
{
    [Fact] public void A() { }
}
public sealed class Concrete : Base<string> { }
public class Other : N.Base<int>, IDisposable { public void Dispose() { } }
public abstract class Mid : Base<object> { }
public class Leaf : Mid { }
