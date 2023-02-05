.\" Disable page numbers in the ms macros.
.ds CH
.\"
.nr PS 9
.fam P
.ps 10
.TL
.pc
Hell freezes over
.br
.ps 9
.B "Freezing Limbo modules to reduce Inferno's memory footprint"
.AU
.ps 9
David Boddie
david@boddie.org.uk
.AB
.in 0.5i
.ll 5.5i
.ps 9
While Inferno is capable of running on systems with a modest amount of memory, it is sometimes useful to be able to reduce the memory footprint of the running system. This is particularly true of embedded systems with only a few hundred kilobytes of RAM. This paper explores an approach where Dis virtual machine code is retained (``frozen'') in flash memory instead of being loaded into precious RAM.
.AE
.SH
Introduction
.LP
Inferno was designed to have minimal hardware requirements, with a stated baseline of 1 MB of memory and no memory mapping hardware [1]. It was suggested in early publicity [2] that about 512 KB each of RAM and ROM would be enough to ``run an interesting system.`` Ports of Inferno to several systems [3] were made and explored, including some with low amounts of memory [4]. It was also shown to be possible to run Inferno with only 512 KB of RAM using a custom memory allocator [5].
.
.\"Today, a system on a chip (SoC) with hundreds of megabytes of RAM and flash memory can be inexpensively obtained from any of the major silicon vendors. Inferno has already been ported to the original Raspberry Pi [3] architecture, and there are many other opportunities for running native Inferno on similarly capable hardware.

Today, microcontrollers with several hundred kilobytes of RAM and flash memory can be obtained. For example, microcontrollers using cores in the ARM Cortex-M4 series can be found with up to 256 KB of RAM, and those in the Cortex-M7 series can be found with 1 MB or more, making them potential targets for Inferno ports [6]. The discussion below focuses on targets at the lower end of this range, specifically the STM32F405RGT6 microcontroller [7] which has 192 KB of RAM and 1 MB of flash memory.
.
.SH
Challenges
.LP
The first challenge a port to a microcontroller faces is the availability of a compiler. In this case, the Thumb compiler was retrieved from the commit history of the Inferno repository and updated slightly. Beyond this, the two main challenges are the amounts of flash memory and RAM available to use.

The amount of flash memory constrains the size of the operating system and limits the features it can include. In the worst case it may not even be possible to fit a system into the space available. Around 256 KB may be required for a minimal set of features, so the target under discussion has plenty of space for a reasonable system.

The amount of RAM, however, is more limiting. Most Inferno systems tend to run in several megabytes of RAM, and many are copied into RAM on boot-up. Although it was found [5] that 512 KB could be enough to run a useful system if the kernel is run from flash memory, problems can still occur when memory allocation occurs in the running system. In the case of the STM32 target hardware this can manifest in heap allocation errors when trying to run programs.

There are two obvious strategies for dealing with the shortage of RAM:
.IP 1.
Reduce the amount used by the operating system to begin with.
.IP 2.
Reduce the amount of memory requested when loading Limbo modules in the form of
.CW ".dis"
files.
.
.LP
The second approach seemed to be a useful starting point and would still be a beneficial approach for systems that have enough free RAM to begin with, but which use large Limbo modules, since they will still encounter limits to the amount of memory they can allocate.

One strategy for dealing with the shortage of RAM suggested itself when investigating how the Dis virtual machine loads Limbo modules.
.
.SH
Loading Limbo modules
.LP
When the Dis virtual machine [8] loads a Limbo module from a file, it performs a number of steps:
.
.IP 1.
In the
.CW "readmod"
function, raw module data is loaded into a newly allocated memory buffer. The
.CW "parsemod"
function is then called with a new
.CW Module
object to create the suitable data structures needed to run the module code.
.IP 2.
The
.CW "parsemod"
function checks for a suitable magic number at the start of the data, returning if unsuccessful.
.IP 3.
Each section in the module data is decoded and the required amount of memory to  represent it is allocated. The first section contains code, which is decoded and expanded into a sequence of
.CW Inst
structures that is suitable for execution.
.IP 4.
The members of the
.CW Module
object are filled in and the module is linked to an existing list of modules.
.
.LP
Dis normally patches the code as it decodes it into its runnable form, adjusting the instructions that perform branches to refer to the addresses of their target instructions in memory. This patching is necessary because it is not possible to know ahead of time where the code will be allocated.

When processing the code section of the module, two things stand out. The amount of memory used to store the instructions is typically larger than the size of the corresponding code in the original file. In addition, once the instructions have been decoded, they never change. This suggests that they could be retained in flash memory in a pre-decoded form through a process of ``freezing'' at build-time.
.
.SH
Freezing code
.LP
Support for frozen modules requires three things: a tool to create frozen module data at build-time, a way for the virtual machine to recognize frozen modules, and an extension to the virtual machine that can load frozen module data.

A
.CW freeze
tool was created to perform the task of reading an existing module file and writing data structures that can be compiled into the operating system. Reusing code from the virtual machine the tool decodes the instructions in the module's code section, ready to be executed at run-time, but writes the other sections in their original form for the virtual machine to handle in the usual way.

The necessary patching of code might appear to be a problem. However, the address of frozen code is fixed at build-time, allowing the branch addresses to be pre-calculated, and avoiding any need to modify the instructions at run-time.

Another purpose of the
.CW freeze
tool is to create a placeholder module file for each original module. This contains the magic number,
.CW 0xFD15 , 
and the path of the original file within the root file system, allowing the virtual machine to recognize that it refers to frozen data for a particular module. There is no need to include any of the original data.

At run-time, the virtual machine recognizes a frozen module by its magic number,
causing it to divert control to the
.CW loadfrozen
function, which looks up the address of the frozen data using the path encoded in the file. If found, the frozen data is processed in much the same way as a regular module, except that the address of the code is used as-is, and the
.CW frozen
flag is set in the
.CW Module
object.

The build system for the STM32 port was updated with
.CW mk
rules to run the
.CW freeze
tool and build the generated code. The kernel's
.CW main
function was updated to call a function to register the frozen modules with the virtual machine. The modules to be frozen are specified in the root section of the configuration file, using sources that end with the
.CW ".fdis"
suffix:
.sp
.CW "        /dis/env.dis    /dis/env.fdis"
.br
.CW "        /dis/ls.dis     /dis/tiny/ls.fdis"

.LP
These intermediate files are created and read by the
.CW mkroot
script as normal.

.SH
Issues with freezing code and other data
.LP
The virtual machine assumes that the resources held by modules are allocated at run-time, so issues can occur when these resources are no longer needed. The most obvious place where a change was needed is in the
.CW freemod
function which was modified to only free sequences of instructions for non-frozen modules. However, problems still occurred when the
.CW ps
command was run. This was tracked down to the
.CW devprog
device that tries to obtain the size of a running program, with assumptions made in the allocator's
.CW poolmsize
function about where the instructions are stored. Checks for the module's
.CW frozen
flag were used to work around issues like these.

Experiments with freezing other sections of modules were only partially successful. As with frozen code, problems occur when data structures created by the loader are assumed to be managed by the allocator. An analysis of how each section is used by the virtual machine is needed to ensure that there are no surprises at run-time. A minimal approach that only freezes instructions offers most of the benefits of the technique with relatively few changes to the surrounding virtual machine.

.SH
Summary of memory savings
.LP
The use of frozen modules results in two main ways in which memory usage is reduced. The obvious one is the lack of a need to allocate memory for instructions at run-time. Additional savings are made by the use of placeholder files to represent frozen modules instead of including full-size module files in the root file system, leading to smaller allocations when reading them.

A side effect of the use of placeholder files is the reduction in the size of the root filing system itself. Since this data is copied into RAM in this port, moving the contents of modules into the text section means that only references to them in the root file system use up RAM. This means that using frozen modules also reduces the initial RAM requirements of the system. A different approach to handling immutable data would lead to similar benefits for all kinds of data, making this particular benefit obsolete.

.SH
Conclusion
.LP
The work described above shows how a fairly simple change to the Limbo module loader can reduce the size of memory allocations at run-time and reduce the overall memory footprint of an embedded Inferno system. By using a simple technique, immediate improvements



.SH
References
.IP 1.
S. Dorward,
R. Pike, 
D.\ L. Presotto,
D.\ M. Ritchie,
H. Trickey,
P. Winterbottom,
``The Inferno Operating System'',
.I "Bell Labs Technical Journal" ,
Vol. 2,
No. 1,
Winter 1997, pp. 5-18.
.br
https://www.vitanuova.com/inferno/papers/bltj.pdf
.
.IP 2.
``Lucent brews Inferno'',
.I "InfoWorld, October 1996"
.br
https://www.infoworld.com/article/2077261/lucent-brews-inferno.html
.
.IP 3.
Vita Nuova, ``Inferno Ports: Hosted and Native'',
.I "Vita Nuova, 27 April 2005"
.br
https://www.vitanuova.com/inferno/papers/port.pdf
.
.IP 4.
Salva Peiró, ``Inferno DS: Inferno port to the Nintendo DS'',
.I "3\*{rd\*} International Workshop on Plan 9"
.br
http://3e.iwp9.org/iwp9_proceedings08.pdf
.
.IP 5.
Brian L. Stuart, ``Inferno in Embedded Space: Porting to the Sun SPOT'',
.I "8\*{th\*} International Workshop on Plan 9"
.br
http://8e.iwp9.org/sunspot.pdf
.
.IP 6.
Petter Duus Berven, ``Porting Inferno OS to ARMv7-M and Cortex-M7'',
.I "Master's thesis in Computer Science, January 2022"
.br
https://hdl.handle.net/11250/3034870
.
.\".IP 6.
.\"Lynxline,
.\"``Porting Inferno OS to Raspberry Pi'',
.\".br
.\"http://lynxline.com/porting-inferno-os-to-raspberry-pi/
.
.IP 7.
STMicroelectronics, ``STM32F405xx STM32F407xx Datasheet'',
.br
https://www.st.com/en/microcontrollers-microprocessors/stm32f405rg.html
.
.IP 8.
Lucent Technologies Inc, Vita Nuova Limited, ``Dis Virtual Machine Specification'',
.br
https://www.vitanuova.com/inferno/papers/dis.pdf
