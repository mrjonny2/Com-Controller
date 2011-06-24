#include <EEPROM.h>
#include <Wire.h>
#include <NewSoftSerial.h> 
#include <avr/pgmspace.h>
#include <stdio.h>




/* 
 Communications Controller - Program for communicating with the World from the Balloon
 Created by White Star Balloon, December 8, 2010.
 Log:
 -Added Auto Orbcomm Position Report Transmission
 -added cutdown timer change response packet
 -Added uplink and I2C change gateway
 -Changed rejection of long messages to truncation of long messages based on maxTelemLenConst
 -added ATCReport only latest
 -added clearinmg of the SC-Terminated msg queue after a period of 240s without hearing any sats
 -changed inbound queue clearing to only happen once per LOS
 -added packetseqnum++ when inbound queue clearing
 -added i2C command unknown lprintf actual command value in lprintf
 -Added circular buffer for long message queueing
 -Added main loop logic to trigger long message transmission
 */


/***********
 * Satellite To-Do list
 * Implement 
 	-Check status of previous message before trying to delete it
 * Solve
 * To Test
 * - Dupe Commands
 ************/

/*************
 *
 *  Debuging Serial Output Verbosity Compiler options
 *
 ***************/
//***Uncomment this to get main loop serial statements
#define mainLoopDebug
//***Uncomment this to print out EEPROM MEssage QUEUE info
//#define eepQDebug
//***Uncomment this to print out detailed satellite serial data packets
//#define satDataDebug
//#define satPrintEveryIncomingPacketDebug
//Uncomment this to print out the general action labels
#define actionLabels
//***uncomment this to have access to full parameter listing functions, not needed for flight
//#define satAccessAllParameters
//***Uncomment this to have I2C serial debugging output
//#define i2cDebug
//***Uncomment to Skip checking incoming checksums from sat modem
//#define skipSatInCHKs
//***Uncomment to repeat commands to the ground
//define beDuplicitous
//***Uncomment this to turn Sat Modem OFF after boot
//#define simulateSat
//***UNCOMMENT THIS FOR FLIGHT  This turns off orbcomm position reporting
#define sendOrbPositionRpts
//***Uncomment this for serial checksum debugging
//#define checkSumDebug

static FILE mystdout = {0};

/*******************************
 *    Pin declarations         *
 *******************************/
const int sat_da = 2;                              // Satellite Modem Data Available
const int sat_sa = 3;                              // Satellite Modem Satellite Available
const int sat_tx = 4;                              // Satellite Modem Serial Transmit
const int sat_rx = 5;                              // Satellite Modem Serial Receive
const int PWR_EN = 6;                              // Satellite Modem Power Enable
const int sat_cts = 7;                             // Satellite Modem Clear to Send
const int sat_debug_rx = 8;                        // Satellite Modem Debug Receive
const int sat_rts = 9;                             // Satellite Modem Request to Send
const int sat_debug_tx = 10;                       // Sattelite Modem Debug Transmit
const int spare1 = 12;                             // Spare
const int extio1 = 12;                             // Satellite Modem
const int spare2 = 13;                             // Spare 
const int etx2_rx = 14;                            // External Transmitter 2 Receive
const int etx2_tx = 15;                            // External Transmitter 2 Transmit
const int etx1_rx = 16;                            // External Transmitter 1 Receive
const int etx1_tx = 17;                            // External Transmitter 1 Transmit
const int sda = 18;                                // I2C SDA
const int scl = 19;                                // I2C SCL

/*******************************
 *    Address declarations     *
 * These are software variable  *
 *******************************/
const byte i2cFlightComputer = 0x05;                  // Flight Computer I2C Address
const byte i2cCutDown = 0x06;                         // Cut Down Module I2C Address
const byte i2cGroundSupport = 0x07;                   // Ground Support Board I2C Address
const byte i2cCommCtrl = 0x08;                        // Communication Computer I2C Address
const byte i2cBallastCtrl = 0x09;                     // Ballast Computer I2C Address
const byte i2ceePROM = 0x50;                          // EEPROM I2C Address

/*******************************
 *     Constants for Sat Modem *
 *******************************/
const byte packetLengthIndex = 2; 
const byte packetTypeIndex = 1;
const byte packetLLstatusCodeIndex = 4;
const byte packetRetStatusCodeIndex = 5;
const byte packetDTEheader = 0x86;  //0x85 or 0x86 sets the type of packet error tracking
const byte serialRetryLimit = 1;
const byte satIncomingPackLenLimit = 70;
const byte i2cRetryLimit = 10;
const unsigned int maxTelemLenConst = 1024;
const unsigned long satUplinkWaitDelayMillis = 60000;
const byte satParamQOBqty 0x16;
const byte satParamQIBqty 0x15;

/*******************************
 *     Constants for I2C Commands to Comm Controller  *
 *******************************/
const byte i2cCmdSATTXATCRpt = 0x00;
const byte i2cCmdSATTxFrmEEPROM = 0x01;
const byte i2cCmdHFUpdtTelem = 0x02;
const byte i2cCmdHFTxShortRpt = 0x03;
const byte i2cCmdHFSetTxRate = 0x04;
const byte i2cCmdHFSnooze = 0x05;
const byte i2cCmdCDNHeartBeat = 0x06;
const byte i2cCmdCDNSetTimerAndReset = 0x07;
const byte i2cCmdUpdateCurrentEpochTime = 0x08;
const byte i2cCmdUpdateThreeNinersValue = 0x09;
const byte i2cCmdSetGwy = 0x0A;
const byte i2cCmdSendOrbPositRpt = 0x0B;
const byte i2cCmdCDNCUTDOWNNOW = 0x99;
const byte i2cCmdSATPowerOn = 0xBB;
const byte i2cCmdSATPowerOff = 0xAA;
const byte i2cCmdGSPPrint = 0x05;
const byte i2cDataLenConst = 15;

/*******************************
 *   Internal EEPROM Locations         *
 *******************************/
const int EPLOCmessageNum = 0;  // EEPROM address for MHA message number byte
const int EPLOCcmdCounterArrayStart = 2; 
const int EPLENcmdCounterArray = 76;  //76 byte array to store used received command counter numbers.
const int EPLOCAtcReportPairArrayStart = 80;
const int EPLOCAtcReportPairArray = 12;
const int EPLOCI2CEEPLongMSGAddrArrayStart = 96;
const int EPLOCI2CEEPLongMSGAddrArrayLen = 512;


/*******************************
 *     Settings for Sat Modem *
 *******************************/
PROGMEM prog_uchar satInitializeParam[]=  { 
  0x06, 0x28, 0x2D, 0x2F, 0x29, 0x01 };
PROGMEM prog_uchar satInitializeValues[]= { 
  0x01, 0x01, 0x00, 0x00, 0x05, 0x01 };
//  These will only be used for non-flight testing.
#ifdef satAccessAllParameters 
// Add 0x13 sco_msg_queue_size and 0x14 sct_msg_queue_size
PROGMEM prog_uchar satByteParams[]= { //Readable byte length sat parameters
  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0A, 0x0C, 0x0D, 0x0E, 0x0F, 0x15, 0x16, 0x1B, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x30, 0x32, 0x33, 0x34, 0x35, 0x36, 0x39, 0x3A };
PROGMEM prog_uchar satSetupWriteParams[]= {
  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x13, 0x14, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x39, 0x3A, 0x3B };
PROGMEM prog_uchar satSetupWriteByteParams[]= {
  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x13, 0x14, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x39, 0x3A, 0x3B };
PROGMEM prog_uchar satSetupWriteByteValues[]= {
  0x01, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x40, 0x40, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 };
#endif


/*******************************
 *    Variable Declarations    *
 *******************************/
byte messageRefNum=0;
byte gwy_id = 1;
byte satLatestPacNum=0;
unsigned char packetBufferA[satIncomingPackLenLimit];
unsigned char packetBufferB[satIncomingPackLenLimit];
unsigned char packetBufferS[15];
unsigned char packetSeqNum=0;
unsigned char rxerr=0;
boolean satAvailable;
boolean tempBool;
byte i2ccommand;
byte i2cRXCommand[2]={
  0xFF,0xFF};                                      // Global variable for I2C Command Transmission
byte i2cdata[2][i2cDataLenConst]; // Global variable for I2C Data
int i2cdataLen[2]={
  0,0};
byte i2cCmdsStored=0;
byte i2cSel=0;
int i2csentStatus;                                 // Status of I2C Tranismitted Message
unsigned int threeNinersTelem;  //Integer value from 0-999 for Bill Brown's 3 1-ascii integer telemetry value channel.
byte checkSumA,checkSumB;							//Global Fletcher Checksum tracking for byte-by-byte I2C to Sat message sending
byte latestPosition[6] = { 
  0xB1, 0x9B, 0x49, 0xBE, 0x07, 0xC3 };  //Place to store the latest position, orbcomm compressed format: lat0 lat1 lat2 lon0 lon1 lon2
unsigned int epochMinutes=0;  //Last time received from Flight Computer, in Minutes (+/- 1 minute accuracy) 
//^^^^^^^^^^^^^^^^^^^^^^^^^     this is NOT updated regularly, only during an ATC short report TX
byte minutesBetweenOrbPositionRpts = 120;  //Send a position report to orbcomm every X minutes
unsigned int lastTimeOrbPositionRptSent = 0; //Store the last epoch time in here
boolean ATCRptReady = false; //Set to true if there's an ATC report waiting to be sent.
boolean LongMsgReady = false; //Set to true if there's a long Message waiting to be sent.
byte satMHANumReportA = 0xFF;  // Store the MHA Ref Num of Sat Queued ATC Report A
byte satMHANumReportB = 0xFF;  // Store the MHA Ref Num of Sat Queued ATC Report B
byte satMsgTermClearoutCounter = 0;
boolean satInboundMsgsCleared = false;
boolean satSyncFlag = false;
boolean prevSatSyncStateFlag = false;
boolean satATCRptPairSittingInSatModemQueue = false;
boolean satWaitingForUplinkCmdsFlag = false;
unsigned long satWaitIsOverTime = 0;
boolean satLongMsgStored = false;
boolean satOBQueueEmpty = true;
boolean satLongMsgInOBQ = false;
byte satLongMsgInOBQMHA = 0xFF;

/*******************************
 *    Queue Ring Buffer Vars   *
 *******************************/
unsigned int EPLOCI2CEEPLongMSGAddrArrayDataStart = 0;
unsigned int EPLOCI2CEEPLongMSGAddrArrayDataEnd = 0;	


/*******************************
 *    Serial declarations      *
 *******************************/
NewSoftSerial sat(sat_tx,sat_rx);
NewSoftSerial hf(etx1_tx,etx1_rx);
NewSoftSerial cdn(etx2_tx,etx2_rx);

extern "C" int lprintf(char*, ...);
extern "C" int lprintf_P(const char*, ...);	


void setup() {
  /*******************************
   *
   *   Pin I/O direction setting
   *
   ********************************/
  pinMode(sat_da, INPUT);
  pinMode(sat_sa, INPUT);
  pinMode(sat_tx, INPUT);
  pinMode(sat_rx, OUTPUT);
  pinMode(PWR_EN, OUTPUT);
  pinMode(sat_cts, INPUT);
  pinMode(sat_debug_rx, OUTPUT);
  pinMode(sat_rts, OUTPUT);
  pinMode(sat_debug_tx, INPUT);
  pinMode(spare1, INPUT);
  pinMode(extio1, INPUT);
  pinMode(spare2, OUTPUT);                                // LED Pin
  pinMode(etx2_rx, OUTPUT);
  pinMode(etx2_tx, INPUT);
  pinMode(etx1_rx, OUTPUT);
  pinMode(etx2_tx, INPUT);
  pinMode(sda, INPUT);
  pinMode(scl, INPUT);

  /*************************
   *
   *  Set Pullups
   *
   **************************/
  digitalWrite(sat_da, LOW);

  /*********************
   *
   * Serial ports initialization
   *
   **********************/
    fdev_setup_stream(&mystdout,output_putchar,NULL,_FDEV_SETUP_WRITE);
	stdout = &mystdout; //Required for printf init
	

  hf.begin(4800);                                        // start the HF transmitter Serial Port
  sat.begin(9600);                                        // Start Satellite Serial Port
  cdn.begin(1200);    									//Start cutdown Serial Port 
  Serial.begin(9600);                                     // Start hardware UART Serial Port for debugging
  delay(2500);
  Serial.println("Booting");  
  delay(500);
  /********************
   *
   *  Proceed with normal operation
   *
   ********************/
  cdnInit();
  satInitRoutine(0);  //0= skip setting init values, 1=Set a few params, 2= set most params.  Will power the modem on.  DO NOT COMMENT OUT
  //satPrintAllParameters();
  i2cInitRoutine();   //Initialize i2c as a slave device

#ifdef simulateSat
    digitalWrite(PWR_EN,LOW);
  lprintf("CC:SATMODEM OFF");
#endif

    //  byte temp = satGetByteParameter(packetBufferB,0x0D);  // Get sat modem diagnostic status
  //printf_P(PSTR("m10 Diag Code: "));
  //Serial.println(temp,DEC);
  printf_P(PSTR("Booted."));

  lprintf_P("CC: Booted\n");

  /*
  // Manual 6-byte command
   packetBufferS[0]= 'T';
   packetBufferS[1]= 'M';
   packetBufferS[2]= 'R';
   packetBufferS[3]= 'x';
   packetBufferS[4]= 'x';
   packetBufferS[5]= 'x';
   packetBufferS[6]= 'e';
   packetBufferS[7]= 'e';
   packetBufferS[8]= 'e';
   packetBufferS[9]= 'e';
   satSendDefaultReport(packetBufferS,packetBufferB);
   */

  //satSendSCOrigPositionRpt(latestPosition,packetBufferS);  //Defaults to Lousiville, KY
   #ifndef mainLoopDebug
   	Serial.println(" NO MAIN DBUG");
   #endif
}



void loop() {
  unsigned long time, timestart, qchecktime=0;
  unsigned char cycle,r;
  byte tempOBQ=0;

  //Wake up the sat port
  sat.available();

  //Set start of loop time for later delay of at least 1s
  time = millis();
  timestart = time;

  //check to see if we should be checking the time for the sat uplink wait delay
  if (true == satWaitingForUplinkCmdsFlag) {  //True if we're waiting
    if (time > satWaitIsOverTime) {  //True if we've passed the delay appointment end time
      satWaitingForUplinkCmdsFlag = false;  //Set the waiting flag to false, will allow things to be sent
    }
  }


  // This just makes sure any random info packets from sat modem get dealt with soon after they arrive 
  //  in the NewSoftSerial 64 byte buffer.  This should wait for new data for only 6 to 10 seconds. 
  //  Satcom should send anything that's waiting every 5 sec
  while (sat.available()){  //available means there's NewSoftSerial data buffered in from the sat modem
    satPacketReceptionist(packetBufferB);
  }  

  // Check for I2C inbound things to process that came in during interrupts
  if (i2cCmdsStored > 0) {
    //If there's 1 command stored, then select #0
    //If there's 2 commnds stored, then select #1
    i2cSel = i2cCmdsStored-1;  
    //Parse selected command
    I2CParse(i2cRXCommand[i2cSel]);                                      // Parse the command that was received
    i2cCmdsStored--;  // After done processing, decrement the stored tally
    msgCounterHouseKeeping();  //Checks to see if variable messageRefNum is OK
  }
  satAOSLOSAlert();  //alert upon Aquisition of signal and Loss of signal
  satClearInboundMsgsIfNeeded();   // Clear inbound satellite messages from the sat modem internal queue whenever there's no sat signal
  satOutgoingMsgOperations();


#ifdef mainLoopDebug
	
  //Generates serial debugging output visual pattern, not for flight!
  if (digitalRead(sat_sa)){
    printf_P(PSTR("|"));  // Generate vertical bars if there's sat signal
  } 
  else {
    printf_P(PSTR("."));
  }
  cycle = random(100);
  if ( 95 < cycle ) {
    Serial.println();
  //Check Queue values every so often
  //if (qchecktime+15000 < time) {  
	  printf_P(PSTR(" q16:"));
	  tempOBQ = satGetByteParameter(packetBufferB, 0x16);
	  printf_P(PSTR("%x  q15:"),tempOBQ);
	  tempOBQ = satGetByteParameter(packetBufferB, 0x15);
	  printf_P(PSTR("%x "),tempOBQ);
	  //qchecktime = time;
  //}
  }
#endif
    //BROKEN!! FIX THIS to use i2c multiple command buffer.
#ifdef beDuplicitous
    //This will repeat the previous I2C command if it was a downlink report.
    // It will only happen every time the terminal screen executes a new line.
    if (i2cRXCommand[i2cSel] == i2cCmdSATTXATCRpt) {
      printf_P(PSTR("willdupe"));
      I2CAwaits = true;  //ooh, sneaky.
      --messageRefNum; //devious too.
      --messageRefNum;  //sent two packets, so need to back up two
    }
    // Check for I2C inbound things to process that came in earlier
    if (I2CAwaits == true) {
      I2CAwaits = false;
      I2CParse(i2ccommand);                                      // Parse the command that was received
    }
#endif
  

  time = millis();
  while (timestart+1000>time){
    time = millis();
  }

}

static int output_putchar(char c, FILE *stream)
{
    if (c == '\n') output_putchar('\r', stream);
    Serial.print(c);
    return 0;
}



