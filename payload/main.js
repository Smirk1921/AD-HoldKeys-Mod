// Modules to control application life and create native browser window
const {app, Menu, BrowserWindow, globalShortcut} = require('electron')
const path = require('path')
const holdKeysMain = require('./AppFiles/js/hold-keys-main')

app.commandLine.appendSwitch('disable-background-timer-throttling')
app.commandLine.appendSwitch('disable-renderer-backgrounding')
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows')
holdKeysMain.install()

function createWindow () {
  // Create the browser window.
  const mainWindow = new BrowserWindow({
    width: 1250,
    height: 760,
    resizable: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: true,
      backgroundThrottling: false,
      contextIsolation: false,
      nativeWindowOpen: true
    }
  })

  holdKeysMain.attachWindow(mainWindow)

  // and load the index.html of the app.
  mainWindow.loadFile('AppFiles/index.html')

  if (process.platform === 'darwin') {
    const template = [
        {
          label: app.getName(),
          submenu: [{ role: 'about' }, { type: 'separator' }, { role: 'hide' }, { role: 'hideothers' }, { role: 'unhide' }, { type: 'separator' }, { role: 'quit' }]
        },
        {
          label: 'Edit',
          submenu: [{ role: 'undo' }, { role: 'redo' }, { type: 'separator' }, { role: 'cut' }, { role: 'copy' }, { role: 'paste' }]
        },
        {
          label: 'View',
          submenu: [{ role: 'togglefullscreen' }]
        },
        {
          role: 'window',
          submenu: [{ role: 'minimize' }, { role: 'close' }]
        }
    ];
      Menu.setApplicationMenu(Menu.buildFromTemplate(template));
      globalShortcut.register('F10', () => {
        mainWindow.setFullScreen(!mainWindow.isFullScreen())
      })
  } else {
      Menu.setApplicationMenu(null)
      globalShortcut.register('F10', () => {
        mainWindow.setFullScreen(!mainWindow.isFullScreen())
      })
  }
  mainWindow.setMenuBarVisibility(false)

  // Open the DevTools.
    //mainWindow.webContents.openDevTools()
    /*
    globalShortcut.register('CommandOrControl+Shift+Alt+D',() => {
      !mainWindow.webContents.isDevToolsOpened() ? mainWindow.webContents.openDevTools() : mainWindow.webContents.closeDevTools()
    })
    globalShortcut.register('CommandOrControl+Shift+Option+D',() => {
      !mainWindow.webContents.isDevToolsOpened() ? mainWindow.webContents.openDevTools() : mainWindow.webContents.closeDevTools()
    })
    */
}

// This method will be called when Electron has finished
// initialization and is ready to create browser windows.
// Some APIs can only be used after this event occurs.
app.whenReady().then(() => {
  app.allowRendererProcessReuse = false
  createWindow()

  app.on('activate', function () {
    // On macOS it's common to re-create a window in the app when the
    // dock icon is clicked and there are no other windows open.
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

// Quit when all windows are closed, except on macOS. There, it's common
// for applications and their menu bar to stay active until the user quits
// explicitly with Cmd + Q.
app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit()
})

// In this file you can include the rest of your app's specific main process
// code. You can also put them in separate files and require them here.
