using LibD2.Drlg;
using Xunit;

namespace LibD2.Tests;

/// <summary>The map generator through the generated layer: an act comes back with its levels, rooms,
/// presets and collision.</summary>
public class DrlgTests
{
    [Fact]
    public void ActOneHasTheBloodMoor()
    {
        using var g = new MapGenerator();
        var act = g.GenerateAct(1337, Difficulty.Normal, 0, includeCollision: true);
        var moor = act.GetLevel(2);
        Assert.NotNull(moor);
        Assert.Equal("Blood Moor", moor!.Name);
        Assert.NotEmpty(moor.Rooms);
        Assert.NotEmpty(moor.Presets);
        Assert.NotEmpty(moor.Adjacents);
        Assert.NotNull(moor.Collision);
    }
}
