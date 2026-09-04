using System.Threading.Channels;

namespace ClipPlayer.Core;

/// <summary>One FIFO worker for state/output commands; decoding is deliberately outside this queue.</summary>
public sealed class PlaybackCommandQueue : IAsyncDisposable
{
    private readonly Channel<Func<ValueTask>> _commands = Channel.CreateUnbounded<Func<ValueTask>>(
        new UnboundedChannelOptions { SingleReader = true, SingleWriter = false, AllowSynchronousContinuations = false });
    private readonly Task _worker;

    public PlaybackCommandQueue() => _worker = RunAsync();

    public async ValueTask EnqueueAsync(Func<ValueTask> command)
    {
        ArgumentNullException.ThrowIfNull(command);
        var completion = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        await _commands.Writer.WriteAsync(async () =>
        {
            try { await command(); completion.SetResult(null); }
            catch (Exception exception) { completion.SetException(exception); }
        }).ConfigureAwait(false);
        await completion.Task.ConfigureAwait(false);
    }

    public async ValueTask<T> EnqueueAsync<T>(Func<ValueTask<T>> command)
    {
        ArgumentNullException.ThrowIfNull(command);
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        await _commands.Writer.WriteAsync(async () =>
        {
            try { completion.SetResult(await command()); }
            catch (Exception exception) { completion.SetException(exception); }
        }).ConfigureAwait(false);
        return await completion.Task.ConfigureAwait(false);
    }

    private async Task RunAsync()
    {
        await foreach (var command in _commands.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            await command().ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        _commands.Writer.TryComplete();
        await _worker.ConfigureAwait(false);
    }
}
