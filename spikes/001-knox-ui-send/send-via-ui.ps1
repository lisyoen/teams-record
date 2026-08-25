param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+$')]
    [string]$ChannelId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Message,

    [int]$InspectorPort = 9229
)

$ErrorActionPreference = 'Stop'

function Receive-CdpResponse {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$RequestId
    )

    $token = [Threading.CancellationToken]::None
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $buffer = New-Object byte[] 262144
        $segment = [ArraySegment[byte]]::new($buffer)
        $builder = [Text.StringBuilder]::new()
        do {
            $result = $Socket.ReceiveAsync($segment, $token).GetAwaiter().GetResult()
            [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
        } while (-not $result.EndOfMessage)

        $text = $builder.ToString()
        try {
            $payload = $text | ConvertFrom-Json
            if ($payload.id -eq $RequestId) {
                return $payload
            }
        } catch {
            # Ignore inspector events and continue until the matching response arrives.
        }
    }
    throw "CDP response timeout for request $RequestId"
}

$targets = Invoke-RestMethod "http://127.0.0.1:$InspectorPort/json/list"
$target = @($targets) | Where-Object { $_.type -eq 'node' } | Select-Object -First 1
if (-not $target) {
    throw "KnoxTeams main inspector was not found on 127.0.0.1:$InspectorPort"
}

$channelB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ChannelId))
$messageB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Message))
$messageJson = $Message | ConvertTo-Json -Compress

$expression = @"
(async () => {
  const electron = process.mainModule.require('electron');
  const channelId = Buffer.from('$channelB64', 'base64').toString('utf8');
  const message = Buffer.from('$messageB64', 'base64').toString('utf8');
  const targetHash = '#/workspace/' + channelId;
  const contents = electron.webContents.fromId(1);
  if (!contents || contents.isDestroyed()) throw new Error('main renderer not available');
  const debuggerApi = contents.debugger;
  const attachedHere = !debuggerApi.isAttached();
  if (attachedHere) debuggerApi.attach('1.3');
  try {
    if (!contents.getURL().includes(targetHash)) {
      await debuggerApi.sendCommand('Runtime.evaluate', {
        expression: 'location.hash=' + JSON.stringify(targetHash)
      });
      await new Promise(resolve => setTimeout(resolve, 1800));
    }
    if (!contents.getURL().includes(targetHash)) {
      throw new Error('target channel navigation failed: ' + contents.getURL());
    }
    await debuggerApi.sendCommand('Runtime.evaluate', {
      expression: `(() => {
        const trigger = document.querySelector('input[placeholder^="새 대화 주제를 입력하세요"]');
        if (!trigger) throw new Error('composer trigger not found');
        trigger.click();
        trigger.focus();
      })()`
    });
    await new Promise(resolve => setTimeout(resolve, 600));
    await debuggerApi.sendCommand('Runtime.evaluate', {
      expression: `(() => {
        const editor = document.querySelector('.ProseMirror.toastui-editor-contents');
        if (!editor) throw new Error('composer editor not found');
        editor.focus();
      })()`
    });
    await debuggerApi.sendCommand('Input.insertText', { text: message });
    await new Promise(resolve => setTimeout(resolve, 800));
    const readiness = await debuggerApi.sendCommand('Runtime.evaluate', {
      expression: `(() => {
        const editor = document.querySelector('.ProseMirror.toastui-editor-contents');
        const button = document.querySelector('button[title="전송"]');
        return JSON.stringify({
          text: editor && editor.innerText,
          buttonFound: !!button,
          disabled: button && button.disabled
        });
      })()`,
      returnByValue: true
    });
    const state = JSON.parse(readiness.result.value);
    if (!state.buttonFound || state.disabled || state.text !== message) {
      throw new Error('composer state mismatch: ' + JSON.stringify(state));
    }
    await debuggerApi.sendCommand('Runtime.evaluate', {
      expression: `(() => {
        const button = document.querySelector('button[title="전송"]');
        if (!button || button.disabled) throw new Error('send button unavailable');
        button.click();
      })()`
    });
    await new Promise(resolve => setTimeout(resolve, 2200));
    const verification = await debuggerApi.sendCommand('Runtime.evaluate', {
      expression: `JSON.stringify({
        url: location.href,
        visible: (document.body && document.body.innerText || '').includes($messageJson),
        processAlive: true
      })`,
      returnByValue: true
    });
    return verification.result.value;
  } finally {
    if (attachedHere && debuggerApi.isAttached()) debuggerApi.detach();
  }
})()
"@

$requestId = 1
$request = @{
    id = $requestId
    method = 'Runtime.evaluate'
    params = @{
        expression = $expression
        awaitPromise = $true
        returnByValue = $true
    }
} | ConvertTo-Json -Compress -Depth 8

$socket = [Net.WebSockets.ClientWebSocket]::new()
$token = [Threading.CancellationToken]::None
try {
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, $token).GetAwaiter().GetResult()
    $bytes = [Text.Encoding]::UTF8.GetBytes($request)
    $segment = [ArraySegment[byte]]::new($bytes)
    $socket.SendAsync(
        $segment,
        [Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        $token
    ).GetAwaiter().GetResult()
    $response = Receive-CdpResponse -Socket $socket -RequestId $requestId
    if ($response.result.exceptionDetails) {
        throw $response.result.exceptionDetails.exception.description
    }
    $response.result.result.value
} finally {
    $socket.Dispose()
}
