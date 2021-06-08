

  

  

  

# BigBlueButton Exporter

  

⚠️ **Still a work in progress!** ⚠️<br  />

  

A server-side script to export a BigBlueButton 2.3-dev recording as a single video file.

  

## What's supported?

  

✅ Whiteboard slides with annotations <br  />

  

✅ Webcams <br  />

  

✅ Screen shares <br  />

  

✅ Polls <br  />

  

✅ Cursor <br  />

  

✅ Zooms <br  />

  

✅ Text <br  />

  

✅ Chat <br  />

  
## [Demonstration](https://drive.google.com/file/d/1H5004sX6OLdZBrs6gS-nWsm2HTyuRhUy/view)

![BigBlueButton Recording Exporter - render into mp4 file](https://i.imgur.com/CjSFtzi.png "BBB video meeting exporter")



## What's coming?

🔜 Faster, less resource-intensive exports<br  />

🔜  A detailed documentation in the form of my Bachelor's Thesis at the Technical University of Munich<br  />

## Usage
Place the files `render_chat.rb`, `render_cursor.rb`, and `render_whiteboard.rb` in `/usr/local/bigbluebutton/core/scripts/post_publish` with executable rights.

BBB sessions will then automatically be exported as a `meeting.mp4` file, which can be accessed and downloaded at https://`your.bbb.hostname`/presentation/`meeting-id`/meeting.mp4

The meeting's ID is the alphanumeric string following the 2.3 in the recording's URL.

Existing recordings can be rebuilt to run the exporting scripts automatically again.

If you do not have access to a BBB server, check out the branch 'client-side'.

To add a download button to Greenlight's UI, change [these](https://github.com/danielpetri1/greenlight/commit/72c2165e4a504aa40e116a83864de36dea540b65) files.
 
## Requirements
Access to a functioning BBB 2.3 server. <br  />

## Disclaimer
As this project is still a work in progress, long BBB sessions or meetings that contain a large amount of chat messages / whiteboard annotations may take up a lot of hard disk space and be slow to render. The contents of the created scratch folders are **not** automatically deleted.

A license may be needed for the generated .mp4 files.
